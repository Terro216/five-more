import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/app/theme.dart';
import 'package:five_more/features/alarms/alarm_editor.dart';
import 'package:five_more/features/alarms/ringing_screen.dart';
import 'package:five_more/models/alarm.dart';
import 'package:five_more/models/snooze_position.dart';
import 'package:five_more/models/wake_preset.dart';
import 'package:five_more/services/alarm_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'alarm_fakes.dart';

const _alarm = Alarm(
  id: 'moving-morning',
  hour: 7,
  minute: 30,
  maxSnoozes: 4,
  moveSnoozeButton: true,
);

RingingAlarm _ring(int used, {String occurrence = 'morning:2026-10-23'}) =>
    RingingAlarm(
      alarm: _alarm,
      occurrenceId: occurrence,
      firedAt: DateTime(2026, 10, 23, 7, 30),
      snoozesUsed: used,
    );

const _snooze = ValueKey('ringing-snooze');

class _FailingSnoozeGateway extends FakeAlarmGateway {
  bool reject = true;

  @override
  Future<AlarmResult> snooze(String id, {int? minutes}) async {
    if (!reject) return super.snooze(id);
    snoozeCalls.add(id);
    return AlarmResult(
      ok: false,
      error: List.filled(
        6,
        'Система не подтвердила перенос. Попробуй ещё раз.',
      ).join(' '),
    );
  }
}

Future<void> _mount(
  WidgetTester tester,
  AlarmController controller, {
  Size size = const Size(390, 844),
  double textScale = 1,
  EdgeInsets insets = EdgeInsets.zero,
  Widget? home,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: fiveMoreTheme(),
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          padding: insets,
          viewPadding: insets,
        ),
        child: child!,
      ),
      home:
          home ??
          AnimatedBuilder(
            animation: controller,
            builder: (context, _) {
              final ringing = controller.ringing;
              return ringing == null
                  ? const Scaffold(body: Text('Звонок завершён'))
                  : RingingScreen(
                      key: ValueKey(ringing.occurrenceId),
                      controller: controller,
                      ringing: ringing,
                    );
            },
          ),
    ),
  );
  await tester.pumpAndSettle();
}

void _expectControlsVisible(WidgetTester tester, Size size, EdgeInsets insets) {
  for (final key in [
    'ringing-snooze',
    'ringing-start-challenge',
    'ringing-emergency',
  ]) {
    final control = find.byKey(ValueKey(key));
    expect(control.hitTestable(), findsOneWidget, reason: key);
    final rect = tester.getRect(control);
    expect(rect.top, greaterThanOrEqualTo(insets.top), reason: key);
    expect(
      rect.bottom,
      lessThanOrEqualTo(size.height - insets.bottom),
      reason: key,
    );
    expect(rect.left, greaterThanOrEqualTo(insets.left), reason: key);
    expect(
      rect.right,
      lessThanOrEqualTo(size.width - insets.right),
      reason: key,
    );
    expect(rect.height, greaterThanOrEqualTo(48), reason: key);
  }
  expect(tester.takeException(), isNull);
}

void main() {
  test('moving snooze is opt-in and survives stored alarm round trips', () {
    final legacyJson = _alarm.toJson()..remove('moveSnoozeButton');
    expect(Alarm.fromJson(legacyJson).moveSnoozeButton, isFalse);
    expect(Alarm.fresh().moveSnoozeButton, isFalse);
    expect(Alarm.fromJson(_alarm.toJson()).moveSnoozeButton, isTrue);
    expect(_alarm.copyWith(title: 'Другое имя').moveSnoozeButton, isTrue);
    expect(_alarm.copyWith(moveSnoozeButton: false).moveSnoozeButton, isFalse);
    for (final preset in WakePreset.values) {
      expect(preset.applyTo(_alarm).moveSnoozeButton, isTrue);
    }
  });

  test(
    'every next native snooze changes tile without process-local randomness',
    () {
      for (final occurrence in [
        'morning:2026-10-23',
        'morning:2026-10-24',
        'утро:42',
      ]) {
        final positions = List.generate(
          11,
          (used) => snoozeTileFor(occurrence, used),
        );
        for (var used = 1; used < positions.length; used++) {
          expect(positions[used], isNot(positions[used - 1]));
        }
        final restored = RingingAlarm.fromJson({
          'alarm': _alarm.toJson(),
          'occurrenceId': occurrence,
          'firedAt': DateTime(2026, 10, 23).millisecondsSinceEpoch,
          'snoozesUsed': 5,
        });
        expect(
          snoozeTileFor(restored.occurrenceId, restored.snoozesUsed),
          positions[5],
        );
      }
      expect(snoozeTileFor('morning', -1), snoozeTileFor('morning', 0));
    },
  );

  for (final scenario in [
    (
      name: 'portrait',
      size: const Size(390, 844),
      scale: 1.0,
      insets: const EdgeInsets.only(top: 24, bottom: 24),
    ),
    (
      name: 'small phone at 2x',
      size: const Size(320, 640),
      scale: 2.0,
      insets: const EdgeInsets.only(top: 24, bottom: 24),
    ),
    (
      name: 'landscape at 1.5x',
      size: const Size(844, 390),
      scale: 1.5,
      insets: const EdgeInsets.only(left: 44, right: 44, bottom: 21),
    ),
  ]) {
    testWidgets(
      'all moving positions fit ${scenario.name} and clear the previous tap',
      (tester) async {
        final gateway = FakeAlarmGateway()..ringing = _ring(0);
        final controller = AlarmController(
          gateway: gateway,
          storage: MemoryAlarmStorage(),
        );
        addTearDown(controller.dispose);
        await controller.initialize(startPolling: false);
        await _mount(
          tester,
          controller,
          size: scenario.size,
          textScale: scenario.scale,
          insets: scenario.insets,
        );
        Rect? previous;
        for (var used = 0; used < 4; used++) {
          gateway.ringing = _ring(used);
          await controller.poll();
          await tester.pumpAndSettle();
          _expectControlsVisible(tester, scenario.size, scenario.insets);
          final rect = tester.getRect(find.byKey(_snooze));
          if (previous != null) {
            expect(rect, isNot(previous));
            expect(
              rect.contains(previous.center),
              isFalse,
              reason: 'An automatic tap at the previous center must miss.',
            );
          }
          previous = rect;
        }
        await tester.tap(find.byKey(_snooze));
        await tester.pumpAndSettle();
        expect(gateway.snoozeCalls, [_alarm.id]);
        expect(gateway.dismissCalls, isEmpty);
        expect(controller.ringing, isNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'the same native ring keeps its position across ticks and reopening',
    (tester) async {
      final gateway = FakeAlarmGateway()..ringing = _ring(2);
      final controller = AlarmController(
        gateway: gateway,
        storage: MemoryAlarmStorage(),
      );
      addTearDown(controller.dispose);
      await controller.initialize(startPolling: false);
      await _mount(tester, controller);
      final rect = tester.getRect(find.byKey(_snooze));
      await tester.pump(const Duration(seconds: 7));
      await controller.poll();
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(_snooze)), rect);
      await tester.pumpWidget(const SizedBox.shrink());
      await _mount(tester, controller);
      expect(tester.getRect(find.byKey(_snooze)), rect);
      expect(gateway.snoozeCalls, isEmpty);
      expect(gateway.dismissCalls, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a failed snooze does not move the button or block emergency at 2x',
    (tester) async {
      final gateway = _FailingSnoozeGateway()..ringing = _ring(1);
      final controller = AlarmController(
        gateway: gateway,
        storage: MemoryAlarmStorage(),
      );
      addTearDown(controller.dispose);
      await controller.initialize(startPolling: false);
      const size = Size(320, 640);
      const insets = EdgeInsets.only(top: 24, bottom: 24);
      await _mount(
        tester,
        controller,
        size: size,
        textScale: 2,
        insets: insets,
      );
      final before = tester.getRect(find.byKey(_snooze));
      await tester.tap(find.byKey(_snooze));
      await tester.pumpAndSettle();
      expect(controller.ringing?.snoozesUsed, 1);
      expect(tester.getRect(find.byKey(_snooze)), before);
      expect(find.byKey(const ValueKey('ringing-error')), findsOneWidget);
      _expectControlsVisible(tester, size, insets);
      await tester.tap(find.byKey(const ValueKey('ringing-emergency')));
      await tester.pumpAndSettle();
      expect(find.text('Аварийная остановка'), findsOneWidget);
      expect(gateway.dismissCalls, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'the editor saves and reopens the explicit moving-button choice',
    (tester) async {
      final gateway = FakeAlarmGateway();
      final storage = MemoryAlarmStorage();
      final controller = AlarmController(gateway: gateway, storage: storage);
      addTearDown(controller.dispose);
      await controller.initialize(startPolling: false);
      Future<void> open(Alarm? alarm) async {
        await _mount(
          tester,
          controller,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push<bool>(
                  MaterialPageRoute<bool>(
                    builder: (_) =>
                        AlarmEditor(controller: controller, alarm: alarm),
                  ),
                ),
                child: const Text('Открыть'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Открыть'));
        await tester.pumpAndSettle();
        final vertical = find
            .byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  axisDirectionToAxis(widget.axisDirection) == Axis.vertical,
            )
            .first;
        final advanced = find.byKey(const ValueKey('alarm-advanced'));
        await tester.scrollUntilVisible(advanced, 220, scrollable: vertical);
        await tester.ensureVisible(advanced);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Настроить вручную'));
        await tester.pumpAndSettle();
        final toggle = find.byKey(const ValueKey('move-snooze-button'));
        await tester.scrollUntilVisible(toggle, 220, scrollable: vertical);
        await tester.ensureVisible(toggle);
        await tester.pumpAndSettle();
      }

      await open(null);
      final toggle = find.byKey(const ValueKey('move-snooze-button'));
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save-alarm')));
      await tester.pumpAndSettle();
      expect(gateway.scheduleCalls.single.moveSnoozeButton, isTrue);
      expect(storage.snapshot.alarms.single.moveSnoozeButton, isTrue);
      await open(controller.alarms.single);
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
