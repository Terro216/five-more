import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/app/theme.dart';
import 'package:five_more/features/alarms/alarm_editor.dart';
import 'package:five_more/features/alarms/alarm_home.dart';
import 'package:five_more/features/alarms/device_check_screen.dart';
import 'package:five_more/features/challenges/challenge_models.dart';
import 'package:five_more/features/challenges/challenge_screen.dart';
import 'package:five_more/models/alarm.dart';
import 'package:five_more/models/device_alarm_check.dart';
import 'package:five_more/services/alarm_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'alarm_fakes.dart';

const _morning = Alarm(
  id: 'morning',
  hour: 7,
  minute: 30,
  title: 'Рабочее утро',
  weekdays: [1, 2, 3, 4, 5],
  difficulty: ChallengeDifficulty.easy,
  escalateOnSnooze: true,
);

void main() {
  Future<AlarmController> showHome(
    WidgetTester tester, {
    required FakeAlarmGateway gateway,
    List<Alarm> alarms = const [_morning],
    DeviceAlarmCheck? check,
    double width = 390,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final alarm in alarms) {
      gateway.nativeAlarms[alarm.id] = alarm;
    }
    // Construct the controller's async queue inside testWidgets' clock zone.
    final controller = AlarmController(
      gateway: gateway,
      storage: MemoryAlarmStorage()
        ..snapshot = AlarmSnapshot(alarms: alarms, deviceCheck: check),
      now: () => DateTime(2026, 10, 23, 6),
    );
    addTearDown(controller.dispose);
    await controller.initialize(startPolling: false);
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
        home: AlarmHome(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('first screen keeps the alarm controls clear of the add action', (
    tester,
  ) async {
    final gateway = FakeAlarmGateway();
    await showHome(tester, gateway: gateway);
    final add = find.byKey(const ValueKey('add-alarm'));
    final card = find.byKey(const ValueKey('alarm-card-morning'));
    final toggle = find.byKey(const ValueKey('alarm-toggle-morning'));

    expect(find.text('Пятница, 23 октября'), findsOneWidget);
    expect(find.text('До будильника 1 ч 30 мин'), findsOneWidget);
    expect(find.text('Телефон ещё не проверен'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(toggle.hitTestable(), findsOneWidget);
    expect(
      tester.getRect(card).bottom,
      lessThanOrEqualTo(tester.getRect(add).top),
    );
    expect(
      tester.getRect(add).bottom,
      lessThanOrEqualTo(tester.getRect(find.byType(NavigationBar)).top),
    );

    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(find.byType(AlarmEditor), findsOneWidget);
    expect(tester.widget<AlarmEditor>(find.byType(AlarmEditor)).alarm, isNull);
    expect(gateway.scheduleCalls, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('editing and toggling remain separate actions on an alarm', (
    tester,
  ) async {
    final gateway = FakeAlarmGateway();
    final controller = await showHome(tester, gateway: gateway);
    final card = find.byKey(const ValueKey('alarm-card-morning'));
    await tester.tap(find.descendant(of: card, matching: find.text('07:30')));
    await tester.pumpAndSettle();
    final editor = find.byType(AlarmEditor);
    expect(tester.widget<AlarmEditor>(editor).alarm?.id, 'morning');
    Navigator.of(tester.element(editor)).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('alarm-toggle-morning')));
    await tester.pumpAndSettle();
    expect(controller.alarms.single.enabled, isFalse);
    expect(gateway.scheduleCalls.single.enabled, isFalse);
    expect(find.byType(AlarmEditor), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a rejected toggle keeps its state and exposes the failure', (
    tester,
  ) async {
    final gateway = FakeAlarmGateway()..rejectSchedule = true;
    final controller = await showHome(tester, gateway: gateway);
    await tester.tap(find.byKey(const ValueKey('alarm-toggle-morning')));
    await tester.pumpAndSettle();

    expect(controller.alarms.single.enabled, isTrue);
    expect(find.textContaining('Разрешение не предоставлено'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pending device check remains explicit and opens its status', (
    tester,
  ) async {
    final gateway = FakeAlarmGateway();
    await showHome(
      tester,
      gateway: gateway,
      check: DeviceAlarmCheck(
        sourceAlarmId: 'morning',
        previewAlarmId: 'preview:pending',
        startedAt: DateTime(2026, 10, 23, 5, 59, 50),
        dueAt: DateTime(2026, 10, 23, 6, 0, 10),
      ),
    );
    expect(find.text('Проверка срабатывания начата'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home-device-check')));
    await tester.pumpAndSettle();
    expect(find.byType(DeviceCheckScreen), findsOneWidget);
    expect(gateway.scheduleCalls, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('all five training choices are visible without scrolling', (
    tester,
  ) async {
    final gateway = FakeAlarmGateway();
    await showHome(tester, gateway: gateway);
    await tester.tap(find.text('Задания'));
    await tester.pumpAndSettle();
    final navigationTop = tester.getRect(find.byType(NavigationBar)).top;
    for (final kind in ChallengeKind.values) {
      final row = find.byKey(ValueKey('practice-kind-${kind.name}'));
      expect(row.hitTestable(), findsOneWidget, reason: kind.name);
      final bounds = tester.getRect(row);
      expect(bounds.height, greaterThanOrEqualTo(48));
      expect(
        bounds.bottom,
        lessThanOrEqualTo(navigationTop),
        reason: kind.name,
      );
    }

    await tester.tap(find.text('Порядок'));
    await tester.pumpAndSettle();
    final practice = tester.widget<ChallengeScreen>(
      find.byType(ChallengeScreen),
    );
    expect(practice.kind, ChallengeKind.sequence);
    expect(practice.practice, isTrue);
    expect(gateway.scheduleCalls, isEmpty);
    expect(gateway.dismissCalls, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'narrow enlarged text keeps add, alarm actions and training usable',
    (tester) async {
      final gateway = FakeAlarmGateway();
      await showHome(tester, gateway: gateway, width: 320, textScale: 1.5);
      expect(
        find.byKey(const ValueKey('add-alarm')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      final menu = find.byKey(const ValueKey('alarm-menu-morning'));
      await tester.scrollUntilVisible(menu, 160);
      await tester.pumpAndSettle();
      await tester.ensureVisible(menu);
      await tester.pumpAndSettle();
      expect(menu.hitTestable(), findsOneWidget);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(find.text('Настроить'), findsOneWidget);
      expect(find.text('Удалить'), findsOneWidget);
      Navigator.of(tester.element(find.text('Настроить'))).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Задания'));
      await tester.pumpAndSettle();
      final mixed = find.byKey(const ValueKey('practice-kind-mixed'));
      await tester.scrollUntilVisible(mixed, 160);
      await tester.pumpAndSettle();
      await tester.ensureVisible(mixed);
      await tester.pumpAndSettle();
      expect(mixed.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(mixed);
      await tester.pumpAndSettle();
      expect(
        tester.widget<ChallengeScreen>(find.byType(ChallengeScreen)).kind,
        ChallengeKind.mixed,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('empty preview exposes one create action with enlarged text', (
    tester,
  ) async {
    final gateway = FakeAlarmGateway()..supported = false;
    await showHome(
      tester,
      gateway: gateway,
      alarms: const [],
      width: 320,
      textScale: 1.5,
    );
    expect(find.text('Поставить будильник'), findsOneWidget);
    expect(find.text('Режим знакомства'), findsOneWidget);
    await tester.tap(find.text('Поставить будильник'));
    await tester.pumpAndSettle();
    expect(find.byType(AlarmEditor), findsOneWidget);
    expect(gateway.scheduleCalls, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
