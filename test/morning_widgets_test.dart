import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/app/theme.dart';
import 'package:five_more/features/alarms/alarm_editor.dart';
import 'package:five_more/features/alarms/ringing_screen.dart';
import 'package:five_more/models/alarm.dart';
import 'package:five_more/services/alarm_gateway.dart';
import 'package:five_more/widgets/emergency_stop.dart';
import 'package:five_more/widgets/time_composer.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'alarm_fakes.dart';
import 'ui_helpers.dart';

class _MinuteGateway extends FakeAlarmGateway {
  int? selected;
  @override
  Future<AlarmResult> snooze(String id, {int? minutes}) async {
    selected = minutes;
    return super.snooze(id, minutes: minutes);
  }
}

void main() {
  testWidgets(
    'typing and scrolling update one clock value and reject invalid input',
    (tester) async {
      var value = const TimeOfDay(hour: 7, minute: 30);
      var valid = true;
      await tester.pumpWidget(
        MaterialApp(
          theme: fiveMoreTheme(),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) => TimeComposer(
                time: value,
                onChanged: (v) => update(() => value = v),
                onValidityChanged: (v) => valid = v,
              ),
            ),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('time-hour-input')),
        '23',
      );
      await tester.pump();
      expect(value.hour, 23);
      await tester.enterText(
        find.byKey(const ValueKey('time-minute-input')),
        '99',
      );
      await tester.pump();
      expect(valid, isFalse);
      expect(value.minute, 30);
      await tester.enterText(
        find.byKey(const ValueKey('time-minute-input')),
        '58',
      );
      await tester.pump();
      expect(valid, isTrue);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(
            find.byKey(const ValueKey('time-minute-input')),
          ),
          scrollDelta: const Offset(0, -20),
        ),
      );
      await tester.pump();
      expect(value.minute, 59);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('nap schedules relative to save time, once, across midnight', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 27, 23, 58);
    final gateway = FakeAlarmGateway();
    final controller = AlarmController(
      gateway: gateway,
      storage: MemoryAlarmStorage(),
      now: () => now,
    );
    addTearDown(controller.dispose);
    await controller.initialize(startPolling: false);
    await tester.pumpWidget(
      MaterialApp(
        theme: fiveMoreTheme(),
        home: AlarmEditor(controller: controller),
      ),
    );
    await tester.tap(find.text('Вздремнуть'));
    await tester.pumpAndSettle();
    expect(find.text('Звонок в 00:18 · через 20 мин'), findsOneWidget);
    now = now.add(const Duration(minutes: 2));
    await tester.tap(find.byKey(const ValueKey('save-alarm')));
    await tester.pumpAndSettle();
    expect(
      gateway.scheduleCalls.single.oneShotAt,
      DateTime(2026, 10, 28, 0, 20),
    );
    expect(gateway.scheduleCalls.single.weekdays, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'holding snooze opens slider and passes duration to native only on confirm',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const alarm = Alarm(id: 'a', hour: 7, minute: 30, snoozeMinutes: 5);
      final gateway = _MinuteGateway()
        ..ringing = RingingAlarm(
          alarm: alarm,
          occurrenceId: 'o',
          firedAt: DateTime(2026, 10, 27, 7, 30),
          snoozesUsed: 1,
        );
      final controller = AlarmController(
        gateway: gateway,
        storage: MemoryAlarmStorage(),
      );
      addTearDown(controller.dispose);
      await controller.initialize(startPolling: false);
      await tester.pumpWidget(
        MaterialApp(
          theme: fiveMoreTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: RingingScreen(
            controller: controller,
            ringing: gateway.ringing!,
          ),
        ),
      );
      await tester.longPress(find.byKey(const ValueKey('ringing-snooze')));
      await tester.pump();
      expect(find.byKey(const ValueKey('snooze-slider')), findsOneWidget);
      expect(gateway.snoozeCalls, isEmpty);
      tester.widget<Slider>(find.byType(Slider)).onChanged!(17);
      await tester.pump();
      expect(find.text('После этого останется переносов: 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Отложить на 17 мин'));
      await tester.pump();
      await tester.tap(find.text('Отложить на 17 мин'));
      await tester.pumpAndSettle();
      expect(gateway.selected, 17);
      expect(alarm.snoozeMinutes, 5);
      expect(gateway.dismissCalls, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('emergency requires a fresh code and one uninterrupted minute', (
    tester,
  ) async {
    bool? stopped;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  stopped = await confirmEmergencyStop(context),
              child: const Text('Help'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Help'));
    await tester.pumpAndSettle();
    final firstCode = tester
        .widget<Text>(find.byKey(const ValueKey('emergency-code')))
        .data;
    expect(find.byKey(const ValueKey('emergency-hold')), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('emergency-code-input')),
      '000000000000',
    );
    await tester.pump();
    expect(find.text('Код не совпал'), findsOneWidget);
    expect(stopped, isNull);
    await tester.tap(find.text('Вернуться к заданию'));
    await tester.pumpAndSettle();
    expect(stopped, isFalse);
    stopped = null;
    await tester.tap(find.text('Help'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('emergency-code'))).data,
      isNot(firstCode),
    );
    await enterEmergencyCode(tester);
    final hold = find.byKey(const ValueKey('emergency-hold'));
    var gesture = await tester.startGesture(tester.getCenter(hold));
    await tester.pump(const Duration(seconds: 59));
    expect(stopped, isNull);
    await gesture.up();
    await tester.pump();
    expect(find.text('Удерживай 60 секунд'), findsOneWidget);
    gesture = await tester.startGesture(tester.getCenter(hold));
    await tester.pump(const Duration(seconds: 30));
    await gesture.moveTo(tester.getTopLeft(hold) - const Offset(20, 20));
    await tester.pump(const Duration(seconds: 40));
    expect(stopped, isNull);
    expect(find.text('Удерживай 60 секунд'), findsOneWidget);
    await gesture.up();
    gesture = await tester.startGesture(tester.getCenter(hold));
    await tester.pump(const Duration(seconds: 30));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(seconds: 40));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await gesture.up();
    await tester.pump();
    expect(stopped, isNull);
    gesture = await tester.startGesture(tester.getCenter(hold));
    await tester.pump(const Duration(seconds: 59));
    expect(stopped, isNull);
    await tester.pump(const Duration(seconds: 1));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(stopped, isTrue);
  });

  testWidgets(
    'accessible emergency waits a minute and needs final confirmation',
    (tester) async {
      bool? stopped;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(accessibleNavigation: true),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async =>
                    stopped = await confirmEmergencyStop(context),
                child: const Text('Help'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Help'));
      await tester.pumpAndSettle();
      await enterEmergencyCode(tester);
      final confirm = find.byKey(
        const ValueKey('emergency-accessible-confirm'),
      );
      await tester.tap(confirm);
      await tester.pump(const Duration(seconds: 59));
      expect(tester.widget<OutlinedButton>(confirm).onPressed, isNull);
      expect(stopped, isNull);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Подтвердить остановку'), findsOneWidget);
      expect(stopped, isNull);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(stopped, isTrue);
    },
  );
}
