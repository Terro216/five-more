import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/app/theme.dart';
import 'package:five_more/features/alarms/alarm_editor.dart';
import 'package:five_more/features/challenges/challenge_models.dart';
import 'package:five_more/features/challenges/challenge_screen.dart';
import 'package:five_more/models/alarm.dart';
import 'package:five_more/services/alarm_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'alarm_fakes.dart';

Future<void> _openEditor(
  WidgetTester tester,
  AlarmController controller, {
  Alarm? alarm,
  double width = 390,
  double height = 844,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, height);
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
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push<bool>(
              MaterialPageRoute<bool>(
                builder: (_) =>
                    AlarmEditor(controller: controller, alarm: alarm),
              ),
            ),
            child: const Text('Открыть настройки'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Открыть настройки'));
  await tester.pumpAndSettle();
}

Future<void> _reveal(
  WidgetTester tester,
  Finder finder, {
  double delta = 220,
}) async {
  await tester.scrollUntilVisible(
    finder,
    delta,
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
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _reveal(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

final _save = find.byKey(const ValueKey('save-alarm'));

void main() {
  testWidgets('new alarm saves a normal ring with no title or protections', (
    tester,
  ) async {
    final gateway = FakeAlarmGateway();
    final controller = AlarmController(
      gateway: gateway,
      storage: MemoryAlarmStorage(),
    );
    addTearDown(controller.dispose);
    await controller.initialize(startPolling: false);
    await _openEditor(tester, controller);
    expect(find.text('Как просыпаться'), findsNothing);
    expect(find.text('Отключение'), findsNothing);
    expect(find.byType(ExpansionTile), findsNothing);
    await _tap(tester, find.text('Один раз'));
    await _reveal(tester, find.byKey(const ValueKey('snooze-budget')));
    await _reveal(tester, find.text('Звук и вибрация'));
    await _reveal(tester, find.byKey(const ValueKey('delete-after-dismiss')));
    expect(find.text('Удалить'), findsOneWidget);
    await tester.tap(_save);
    await tester.pumpAndSettle();
    final saved = controller.alarms.single;
    expect(saved.requiresChallenge, isFalse);
    expect(saved.title, '');
    expect(saved.snoozeMinutes, 5);
    expect(saved.snoozeBudget, 15);
    expect(saved.escalateOnSnooze, isFalse);
    expect(saved.vibration, isTrue);
    expect(saved.deleteAfterDismiss, isFalse);
    expect(find.byType(AlarmEditor), findsNothing);
  });

  for (final done in [false, true]) {
    testWidgets(
      '${done ? "Done enables" : "back preserves disabled state of"} a legacy alarm',
      (tester) async {
        const original = Alarm(
          id: 'legacy',
          hour: 6,
          minute: 45,
          enabled: false,
          title: '  Моё утро  ',
          difficulty: ChallengeDifficulty.hard,
          snoozeMinutes: 7,
        );
        final gateway = FakeAlarmGateway()
          ..nativeAlarms[original.id] = original;
        final storage = MemoryAlarmStorage()
          ..snapshot = const AlarmSnapshot(alarms: [original]);
        final controller = AlarmController(gateway: gateway, storage: storage);
        addTearDown(controller.dispose);
        await controller.initialize(startPolling: false);
        await _openEditor(tester, controller, alarm: original);
        if (!done) {
          await _reveal(tester, find.byKey(const ValueKey('alarm-title')));
          await tester.enterText(
            find.byKey(const ValueKey('alarm-title')),
            'Правка',
          );
        }
        await tester.tap(done ? _save : find.byType(BackButton));
        await tester.pumpAndSettle();
        final saved = storage.snapshot.alarms.single;
        expect(saved.enabled, done);
        expect(saved.difficulty, ChallengeDifficulty.hard);
        expect(saved.requiresChallenge, isTrue);
        expect(saved.snoozeMinutes, 7);
        expect(saved.title, done ? original.title : 'Правка');
        expect(find.byType(AlarmEditor), findsNothing);
      },
    );
  }

  for (final width in [390.0, 320.0]) {
    testWidgets(
      'editor controls, keyboard and retry fit $width with large text',
      (tester) async {
        final gateway = FakeAlarmGateway()..rejectSchedule = true;
        final controller = AlarmController(
          gateway: gateway,
          storage: MemoryAlarmStorage(),
        );
        addTearDown(controller.dispose);
        await controller.initialize(startPolling: false);
        await _openEditor(
          tester,
          controller,
          width: width,
          height: width == 320 ? 640 : 844,
          textScale: 1.5,
        );
        await _tap(tester, find.text('С заданием'));
        expect(find.byType(ExpansionTile), findsNothing);
        await _tap(
          tester,
          find.byKey(const ValueKey('challenge-kind-sequence')),
        );
        await _tap(tester, find.byKey(const ValueKey('practice-alarm')));
        expect(
          tester.widget<ChallengeScreen>(find.byType(ChallengeScreen)).kind,
          ChallengeKind.sequence,
        );
        Navigator.of(tester.element(find.byType(ChallengeScreen))).pop();
        await tester.pumpAndSettle();
        await _reveal(tester, find.byKey(const ValueKey('alarm-title')));
        await tester.enterText(
          find.byKey(const ValueKey('alarm-title')),
          'Длинное название для утреннего будильника',
        );
        expect(tester.takeException(), isNull);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tester.tap(_save);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('alarm-save-error')).hitTestable(),
          findsOneWidget,
        );
        expect(_save.hitTestable(), findsOneWidget);
        gateway.rejectSchedule = false;
        await tester.tap(_save);
        await tester.pumpAndSettle();
        expect(find.byType(AlarmEditor), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('normal mode ignores an old unconfigured QR challenge', (
    tester,
  ) async {
    const alarm = Alarm(
      id: 'qr',
      hour: 7,
      minute: 0,
      challengeKind: ChallengeKind.qr,
    );
    final gateway = FakeAlarmGateway()..nativeAlarms[alarm.id] = alarm;
    final controller = AlarmController(
      gateway: gateway,
      storage: MemoryAlarmStorage(),
    );
    addTearDown(controller.dispose);
    await controller.initialize(startPolling: false);
    await _openEditor(tester, controller, alarm: alarm);
    await _tap(tester, find.text('Обычный звонок'));
    await tester.tap(_save);
    await tester.pumpAndSettle();
    expect(find.byType(AlarmEditor), findsNothing);
    expect(controller.alarms.single.requiresChallenge, isFalse);
  });
}
