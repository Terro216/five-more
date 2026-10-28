import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/app/theme.dart';
import 'package:five_more/features/alarms/device_check_screen.dart';
import 'package:five_more/features/alarms/alarm_home.dart';
import 'package:five_more/features/alarms/alarm_editor.dart';
import 'package:five_more/features/alarms/ringing_screen.dart';
import 'package:five_more/models/alarm.dart';
import 'package:five_more/services/alarm_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_check_controller_test.dart'
    show DeviceCheckGateway, DeviceCheckStorage, deviceCheckSourceAlarm;

void main() {
  late DeviceCheckGateway gateway;
  late DeviceCheckStorage storage;
  late AlarmController controller;

  setUp(() {
    gateway = DeviceCheckGateway();
    gateway.nativeAlarms[deviceCheckSourceAlarm.id] = deviceCheckSourceAlarm;
    storage = DeviceCheckStorage()
      ..snapshot = const AlarmSnapshot(alarms: [deviceCheckSourceAlarm]);
  });
  tearDown(() => controller.dispose());

  Future<void> showScreen(
    WidgetTester tester, {
    double width = 390,
    double textScale = 1,
    double height = 844,
    Widget Function(AlarmController)? home,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Construct the async controller queue inside testWidgets' clock zone.
    controller = AlarmController(
      gateway: gateway,
      storage: storage,
      now: () => gateway.currentTime,
    );
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
        home:
            home?.call(controller) ??
            DeviceCheckScreen(
              controller: controller,
              sourceAlarmId: deviceCheckSourceAlarm.id,
            ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('home remains usable on a narrow screen with enlarged text', (
    tester,
  ) async {
    await showScreen(
      tester,
      width: 320,
      textScale: 1.5,
      home: (controller) => AlarmHome(controller: controller),
    );
    expect(find.text('ещё пять'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('editor keeps weekday selection usable with enlarged text', (
    tester,
  ) async {
    await showScreen(
      tester,
      width: 320,
      textScale: 1.5,
      home: (controller) => AlarmEditor(controller: controller),
    );
    await tester.scrollUntilVisible(
      find.text('Пн'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Пн'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('emergency exit stays visible on a landscape ringing screen', (
    tester,
  ) async {
    final ring = RingingAlarm(
      alarm: deviceCheckSourceAlarm,
      occurrenceId: 'landscape',
      firedAt: gateway.currentTime,
      snoozesUsed: 2,
    );
    gateway.ringing = ring;
    await showScreen(
      tester,
      width: 844,
      height: 390,
      textScale: 1.5,
      home: (controller) =>
          RingingScreen(controller: controller, ringing: ring),
    );
    await tester.tap(find.text('Проблема с заданием'));
    await tester.pumpAndSettle();
    expect(find.text('Аварийная остановка'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('narrow enlarged-text layout keeps start and cancel reachable', (
    tester,
  ) async {
    await showScreen(tester, width: 320, textScale: 1.5);
    final start = find.byKey(const ValueKey('device-check-start'));
    await tester.scrollUntilVisible(start, 200);
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(start).onPressed,
      isNotNull,
      reason:
          'busy=${controller.busy}, storage=${controller.storageHealthy}, supported=${controller.device.supported}, canSchedule=${controller.device.canSchedule}',
    );
    await tester.tap(start);
    await tester.pumpAndSettle();

    expect(
      controller.deviceCheck,
      isNotNull,
      reason: 'error=${controller.error}, native calls=${gateway.testCalls}',
    );
    expect(controller.deviceCheck!.pending, isTrue);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('device-check-countdown')),
      200,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('device-check-countdown')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('device-check-heard')), findsNothing);
    expect(tester.takeException(), isNull);

    final cancel = find.byKey(const ValueKey('device-check-cancel'));
    await tester.scrollUntilVisible(cancel, 200);
    await tester.pumpAndSettle();
    await tester.tap(cancel);
    await tester.pumpAndSettle();

    expect(controller.deviceCheck, isNull);
    expect(gateway.cancelTestCalls, ['preview:device-check-1']);
    expect(gateway.cancelCalls, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 30));
    expect(tester.takeException(), isNull);
  });

  testWidgets('deadline reveals manual feedback without claiming delivery', (
    tester,
  ) async {
    await showScreen(tester, width: 320, textScale: 1.5);
    final start = find.byKey(const ValueKey('device-check-start'));
    await tester.scrollUntilVisible(start, 200);
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(start).onPressed,
      isNotNull,
      reason:
          'busy=${controller.busy}, storage=${controller.storageHealthy}, supported=${controller.device.supported}, canSchedule=${controller.device.canSchedule}',
    );
    await tester.tap(start);
    await tester.pumpAndSettle();

    gateway.currentTime = gateway.currentTime.add(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 1));
    expect(controller.deviceCheck!.heard, isNull);
    expect(find.byKey(const ValueKey('device-check-heard')), findsNothing);

    gateway.currentTime = gateway.currentTime.add(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 1));
    expect(controller.deviceCheck!.heard, isNull);
    expect(storage.snapshot.deviceCheck!.confirmedAt, isNull);
    final heard = find.byKey(const ValueKey('device-check-heard'));
    await tester.scrollUntilVisible(heard, 200);
    await tester.pumpAndSettle();
    expect(heard, findsOneWidget);
    expect(
      find.byKey(const ValueKey('device-check-not-heard')),
      findsOneWidget,
    );
    await tester.ensureVisible(heard);
    await tester.tap(heard);
    await tester.pumpAndSettle();

    expect(controller.deviceCheck!.heard, isTrue);
    expect(storage.snapshot.deviceCheck!.heard, isTrue);
    expect(gateway.cancelTestCalls, ['preview:device-check-1']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 30));
    expect(tester.takeException(), isNull);
  });

  testWidgets('scheduling failure stays visible and never starts a countdown', (
    tester,
  ) async {
    gateway.rejectTest = true;
    await showScreen(tester);
    final start = find.byKey(const ValueKey('device-check-start'));
    await tester.scrollUntilVisible(start, 200);
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(start).onPressed,
      isNotNull,
      reason:
          'busy=${controller.busy}, storage=${controller.storageHealthy}, supported=${controller.device.supported}, canSchedule=${controller.device.canSchedule}',
    );
    await tester.tap(start);
    await tester.pumpAndSettle();

    expect(controller.deviceCheck, isNull);
    expect(find.textContaining('Точная доставка запрещена'), findsWidgets);
    expect(find.byKey(const ValueKey('device-check-countdown')), findsNothing);
    expect(find.byKey(const ValueKey('device-check-heard')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('browser preview explains that it cannot test phone delivery', (
    tester,
  ) async {
    gateway.supported = false;
    await showScreen(tester);

    final start = find.byKey(const ValueKey('device-check-start'));
    if (start.evaluate().isNotEmpty) {
      final button = tester.widget<FilledButton>(start);
      expect(button.onPressed, isNull);
    }
    expect(find.textContaining('телефон'), findsWidgets);
    expect(gateway.testCalls, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
