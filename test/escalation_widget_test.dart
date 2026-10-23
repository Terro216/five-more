import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/app/theme.dart';
import 'package:five_more/features/alarms/alarm_editor.dart';
import 'package:five_more/features/alarms/alarm_home.dart';
import 'package:five_more/features/alarms/ringing_screen.dart';
import 'package:five_more/features/challenges/challenge_models.dart';
import 'package:five_more/features/challenges/challenge_screen.dart';
import 'package:five_more/models/alarm.dart';
import 'package:five_more/services/alarm_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'alarm_fakes.dart';

const _alarm = Alarm(
  id: 'escalating-morning',
  hour: 7,
  minute: 30,
  difficulty: ChallengeDifficulty.easy,
  escalateOnSnooze: true,
);

Future<void> _mount(
  WidgetTester tester,
  Widget home, {
  double width = 390,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 844);
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
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: home,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openEditor(
  WidgetTester tester,
  AlarmController controller,
  Alarm alarm, {
  double width = 390,
  double textScale = 1,
}) async {
  await _mount(
    tester,
    Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.of(context).push<bool>(
            MaterialPageRoute<bool>(
              builder: (_) => AlarmEditor(controller: controller, alarm: alarm),
            ),
          ),
          child: const Text('Открыть настройки'),
        ),
      ),
    ),
    width: width,
    textScale: textScale,
  );
  await tester.tap(find.text('Открыть настройки'));
  await tester.pumpAndSettle();
  await _tapScrolled(tester, find.byKey(const ValueKey('alarm-advanced')));
}

Future<void> _tapScrolled(WidgetTester tester, Finder finder) async {
  // A visible title field adds its own horizontal Scrollable to the editor.
  await tester.scrollUntilVisible(
    finder,
    220,
    scrollable: find
        .byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              axisDirectionToAxis(widget.axisDirection) == Axis.vertical,
        )
        .first,
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('editor persists the escalation choice and reopens it', (
    tester,
  ) async {
    final legacy = _alarm.copyWith(escalateOnSnooze: false);
    final gateway = FakeAlarmGateway()..nativeAlarms[legacy.id] = legacy;
    final storage = MemoryAlarmStorage()
      ..snapshot = AlarmSnapshot(alarms: [legacy]);
    // Keep the controller's async queue in testWidgets' clock zone.
    final controller = AlarmController(gateway: gateway, storage: storage);
    addTearDown(controller.dispose);
    await controller.initialize(startPolling: false);
    await _openEditor(tester, controller, legacy);

    final toggle = find.byKey(const ValueKey('escalate-on-snooze'));
    await _tapScrolled(tester, toggle);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    expect(find.textContaining('после 1 переноса: Средне'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('save-alarm')));
    await tester.pumpAndSettle();
    expect(storage.snapshot.alarms.single.escalateOnSnooze, isTrue);
    expect(gateway.scheduleCalls.single.escalateOnSnooze, isTrue);

    await _openEditor(tester, controller, controller.alarms.single);
    await tester.scrollUntilVisible(
      toggle,
      220,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                axisDirectionToAxis(widget.axisDirection) == Axis.vertical,
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('disabling snoozes preserves the saved escalation preference', (
    tester,
  ) async {
    final alarm = _alarm.copyWith(maxSnoozes: 0);
    final gateway = FakeAlarmGateway()..nativeAlarms[alarm.id] = alarm;
    final storage = MemoryAlarmStorage()
      ..snapshot = AlarmSnapshot(alarms: [alarm]);
    final controller = AlarmController(gateway: gateway, storage: storage);
    addTearDown(controller.dispose);
    await controller.initialize(startPolling: false);
    await _openEditor(tester, controller, alarm);

    final toggle = find.byKey(const ValueKey('escalate-on-snooze'));
    await tester.scrollUntilVisible(
      toggle,
      220,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                axisDirectionToAxis(widget.axisDirection) == Axis.vertical,
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);
    expect(find.byKey(const ValueKey('escalation-plan')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('save-alarm')));
    await tester.pumpAndSettle();
    expect(storage.snapshot.alarms.single.escalateOnSnooze, isTrue);
    expect(storage.snapshot.alarms.single.maxSnoozes, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('training uses the selected later ring and survives large text', (
    tester,
  ) async {
    final gateway = FakeAlarmGateway()..nativeAlarms[_alarm.id] = _alarm;
    final storage = MemoryAlarmStorage()
      ..snapshot = const AlarmSnapshot(alarms: [_alarm]);
    final controller = AlarmController(gateway: gateway, storage: storage);
    addTearDown(controller.dispose);
    await controller.initialize(startPolling: false);
    await _openEditor(tester, controller, _alarm, width: 320, textScale: 1.5);

    final selector = find.byType(DropdownButtonFormField<int>);
    await _tapScrolled(tester, selector);
    await tester.tap(find.text('После 2 переносов · Сложно').last);
    await tester.pumpAndSettle();
    await _tapScrolled(tester, find.byKey(const ValueKey('practice-alarm')));
    final challenge = tester.widget<ChallengeScreen>(
      find.byType(ChallengeScreen),
    );
    expect(challenge.difficulty, ChallengeDifficulty.hard);
    expect(challenge.practice, isTrue);
    expect(gateway.snoozeCalls, isEmpty);
    expect(gateway.dismissCalls, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('turning escalation off resets training to the base level', (
    tester,
  ) async {
    final gateway = FakeAlarmGateway()..nativeAlarms[_alarm.id] = _alarm;
    final storage = MemoryAlarmStorage()
      ..snapshot = const AlarmSnapshot(alarms: [_alarm]);
    final controller = AlarmController(gateway: gateway, storage: storage);
    addTearDown(controller.dispose);
    await controller.initialize(startPolling: false);
    await _openEditor(tester, controller, _alarm);

    await _tapScrolled(tester, find.byType(DropdownButtonFormField<int>));
    await tester.tap(find.text('После 2 переносов · Сложно').last);
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('escalate-on-snooze'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButtonFormField<int>), findsNothing);
    await _tapScrolled(tester, find.byKey(const ValueKey('practice-alarm')));
    expect(
      tester.widget<ChallengeScreen>(find.byType(ChallengeScreen)).difficulty,
      ChallengeDifficulty.easy,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('native snooze count selects the challenge again after restart', (
    tester,
  ) async {
    final gateway = FakeAlarmGateway()..nativeAlarms[_alarm.id] = _alarm;
    final storage = MemoryAlarmStorage()
      ..snapshot = const AlarmSnapshot(alarms: [_alarm]);
    for (final used in [1, 2]) {
      gateway.ringing = RingingAlarm.fromJson({
        'alarm': _alarm.toJson(),
        'occurrenceId': 'same-native-occurrence',
        'firedAt': DateTime(2026, 10, 22, 7, 30).millisecondsSinceEpoch,
        'snoozesUsed': used,
      });
      final controller = AlarmController(gateway: gateway, storage: storage);
      try {
        await controller.initialize(startPolling: false);
        await _mount(
          tester,
          RingingScreen(controller: controller, ringing: controller.ringing!),
          width: 320,
          textScale: 1.5,
        );
        expect(
          find.text(
            used == 1
                ? 'Средне · после 1 переноса'
                : 'Сложно · после 2 переносов',
          ),
          findsOneWidget,
        );
        await _tapScrolled(tester, find.text('Пройти задание'));
        expect(
          tester
              .widget<ChallengeScreen>(find.byType(ChallengeScreen))
              .difficulty,
          used == 1 ? ChallengeDifficulty.medium : ChallengeDifficulty.hard,
        );
        expect(gateway.dismissCalls, isEmpty);
        expect(gateway.snoozeCalls, isEmpty);
        expect(controller.ringing!.occurrenceId, 'same-native-occurrence');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      }
    }
  });

  testWidgets('home exposes the enabled escalation policy', (tester) async {
    final gateway = FakeAlarmGateway()..nativeAlarms[_alarm.id] = _alarm;
    final storage = MemoryAlarmStorage()
      ..snapshot = const AlarmSnapshot(alarms: [_alarm]);
    final controller = AlarmController(gateway: gateway, storage: storage);
    addTearDown(controller.dispose);
    await controller.initialize(startPolling: false);
    await _mount(tester, AlarmHome(controller: controller));
    await tester.scrollUntilVisible(find.text('Сложнее после переноса'), 220);
    await tester.pumpAndSettle();
    expect(find.text('Сложнее после переноса'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
