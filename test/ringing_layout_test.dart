import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/app/theme.dart';
import 'package:five_more/features/alarms/ringing_screen.dart';
import 'package:five_more/features/challenges/challenge_models.dart';
import 'package:five_more/features/challenges/challenge_screen.dart';
import 'package:five_more/models/alarm.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'alarm_fakes.dart';

void main() {
  for (final scenario in [
    (
      name: 'small phone',
      size: const Size(320, 640),
      scale: 2.0,
      insets: const EdgeInsets.only(top: 24, bottom: 24),
    ),
    (
      name: 'landscape',
      size: const Size(844, 390),
      scale: 1.5,
      insets: const EdgeInsets.only(left: 44, right: 44, bottom: 21),
    ),
    (
      name: 'phone safe areas',
      size: const Size(393, 852),
      scale: 1.0,
      insets: const EdgeInsets.only(top: 44, bottom: 34),
    ),
  ]) {
    testWidgets('wake controls stay visible with ${scenario.name}', (
      tester,
    ) async {
      tester.view.physicalSize = scenario.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const alarm = Alarm(
        id: 'ring',
        hour: 7,
        minute: 30,
        title: 'Длинное название утреннего будильника',
        difficulty: ChallengeDifficulty.easy,
        escalateOnSnooze: true,
      );
      final gateway = FakeAlarmGateway()
        ..ringing = RingingAlarm(
          alarm: alarm,
          occurrenceId: 'today',
          firedAt: DateTime(2026, 10, 23, 7, 30),
          snoozesUsed: 0,
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
          locale: const Locale('ru'),
          supportedLocales: const [Locale('ru'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: scenario.insets,
              viewPadding: scenario.insets,
              textScaler: TextScaler.linear(scenario.scale),
            ),
            child: child!,
          ),
          home: RingingScreen(
            controller: controller,
            ringing: gateway.ringing!,
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final key in [
        'ringing-start-challenge',
        'ringing-snooze',
        'ringing-emergency',
      ]) {
        final control = find.byKey(ValueKey(key));
        expect(control.hitTestable(), findsOneWidget, reason: key);
        final rect = tester.getRect(control);
        expect(rect.top, greaterThanOrEqualTo(scenario.insets.top));
        expect(
          rect.bottom,
          lessThanOrEqualTo(scenario.size.height - scenario.insets.bottom),
        );
        expect(rect.left, greaterThanOrEqualTo(scenario.insets.left));
        expect(
          rect.right,
          lessThanOrEqualTo(scenario.size.width - scenario.insets.right),
        );
        expect(rect.height, greaterThanOrEqualTo(48));
      }
      await tester.tap(find.byKey(const ValueKey('ringing-start-challenge')));
      await tester.pumpAndSettle();
      expect(find.byType(ChallengeScreen), findsOneWidget);
      expect(gateway.dismissCalls, isEmpty);
      expect(gateway.snoozeCalls, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
