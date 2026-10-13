import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/app/five_more_app.dart';
import 'package:five_more/features/challenges/challenge_screen.dart';
import 'package:five_more/models/alarm.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'alarm_fakes.dart';

void main() {
  testWidgets('first-time preview creates an honest disabled draft', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gateway = FakeAlarmGateway()..supported = false;
    final storage = MemoryAlarmStorage();
    final controller = AlarmController(gateway: gateway, storage: storage);
    await controller.initialize(startPolling: false);
    await tester.pumpWidget(FiveMoreApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('Режим знакомства'), findsOneWidget);
    await tester.tap(find.text('Поставить будильник'));
    await tester.pumpAndSettle();
    expect(find.text('Новый будильник'), findsOneWidget);
    expect(find.text('Сохранить черновик'), findsOneWidget);
    await tester.tap(find.text('Один раз'));
    await tester.tap(find.text('Сохранить черновик'));
    await tester.pumpAndSettle();

    expect(controller.alarms, hasLength(1));
    expect(controller.alarms.single.enabled, isFalse);
    expect(controller.alarms.single.weekdays, isEmpty);
    expect(gateway.scheduleCalls, isEmpty);
    await tester.scrollUntilVisible(find.text('Черновик'), 200);
    expect(find.text('Черновик'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('practice is available before setting any alarm', (tester) async {
    final gateway = FakeAlarmGateway()..supported = false;
    final controller = AlarmController(
      gateway: gateway,
      storage: MemoryAlarmStorage(),
    );
    await controller.initialize(startPolling: false);
    await tester.pumpWidget(FiveMoreApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Задания'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Счёт'));
    await tester.pumpAndSettle();
    expect(find.byType(ChallengeScreen), findsOneWidget);
    expect(find.text('Пробный подъём'), findsOneWidget);
    expect(gateway.scheduleCalls, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'ring covers an open editor and emergency dialog stays above it',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final gateway = FakeAlarmGateway();
      final controller = AlarmController(
        gateway: gateway,
        storage: MemoryAlarmStorage(),
      );
      await controller.initialize(startPolling: false);
      await tester.pumpWidget(FiveMoreApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Поставить будильник'));
      await tester.pumpAndSettle();
      expect(find.text('Новый будильник'), findsOneWidget);

      gateway.ringing = RingingAlarm(
        alarm: const Alarm(id: 'actual-alarm', hour: 7, minute: 30),
        occurrenceId: 'actual-morning',
        firedAt: DateTime(2026, 10, 13, 7, 30),
        snoozesUsed: 1,
      );
      await controller.poll();
      await tester.pumpAndSettle();
      final startChallenge = find.text('Я встаю · пройти задание');
      await tester.ensureVisible(startChallenge);
      await tester.tap(startChallenge);
      await tester.pumpAndSettle();
      expect(find.byType(ChallengeScreen), findsOneWidget);
      expect(gateway.dismissCalls, isEmpty);

      await tester.tap(find.text('Нужно срочно выключить'));
      await tester.pumpAndSettle();
      expect(find.text('Остановить без задания?'), findsOneWidget);
      await tester.tap(find.text('Остановить'));
      await tester.pumpAndSettle();

      expect(gateway.dismissCalls, ['actual-alarm']);
      expect(find.byType(ChallengeScreen), findsNothing);
      expect(find.text('Новый будильник'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
