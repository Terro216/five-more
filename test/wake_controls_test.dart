import 'dart:math';

import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/app/theme.dart';
import 'package:five_more/features/alarms/alarm_editor.dart';
import 'package:five_more/features/challenges/challenge_models.dart';
import 'package:five_more/features/sleep/bedtime_screen.dart';
import 'package:five_more/models/alarm.dart';
import 'package:five_more/services/native_extras.dart';
import 'package:five_more/services/sleep_journal.dart';
import 'package:five_more/widgets/time_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'alarm_fakes.dart';

void main() {
  for (final extend in [false, true]) {
    testWidgets(
      'recording saves at ${extend ? "ten minutes after explicit extension" : "five minutes by default"}',
      (tester) async {
        var stops = 0, extensions = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeExtras.channel, (call) async {
              if (call.method == 'extendRecording') extensions++;
              if (call.method == 'stopRecording') {
                stops++;
                return {'file': 'limit.m4a', 'seconds': extend ? 600 : 300};
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(NativeExtras.channel, null),
        );
        final journal = SleepJournal()..ready = true;
        addTearDown(journal.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: fiveMoreTheme(),
            home: Scaffold(body: BedtimeScreen(journal: journal)),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('record-morning-note')));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 299));
        expect(stops, 0);
        if (extend) {
          await tester.tap(find.textContaining('Ещё 5 минут'));
          await tester.pumpAndSettle();
          expect(extensions, 1);
        }
        await tester.pump(const Duration(seconds: 1));
        if (extend) {
          expect(stops, 0);
          await tester.pump(const Duration(minutes: 5));
        }
        for (
          var attempt = 0;
          attempt < 20 && journal.notes.isEmpty;
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        expect(stops, 1);
        expect(journal.notes.single.seconds, extend ? 600 : 300);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'hour taps, drags and typing advance to minutes after selection',
    (tester) async {
      var time = const TimeOfDay(hour: 7, minute: 30);
      await tester.pumpWidget(
        MaterialApp(
          theme: fiveMoreTheme(),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) => TimeComposer(
                time: time,
                onChanged: (value) => update(() => time = value),
              ),
            ),
          ),
        ),
      );
      final hours = find.widgetWithText(ChoiceChip, 'Часы');
      final minutes = find.widgetWithText(ChoiceChip, 'Минуты');
      final dial = find.byKey(const ValueKey('time-dial'));
      final center = tester.getCenter(dial);
      final radius = tester.getSize(dial).width * .4;
      await tester.tapAt(center + Offset(radius, 0));
      await tester.pump();
      expect(time, const TimeOfDay(hour: 3, minute: 30));
      expect(tester.widget<ChoiceChip>(minutes).selected, isTrue);
      await tester.tapAt(center + Offset(0, -radius));
      await tester.pump();
      expect(time, const TimeOfDay(hour: 3, minute: 0));
      await tester.tap(hours);
      await tester.pump();
      final drag = await tester.startGesture(center + Offset(radius, 0));
      await drag.moveTo(center + Offset(0, radius));
      await tester.pump();
      expect(tester.widget<ChoiceChip>(hours).selected, isTrue);
      expect(time.minute, 0);
      await drag.up();
      await tester.pump();
      expect(time.hour, 6);
      expect(tester.widget<ChoiceChip>(minutes).selected, isTrue);
      await tester.tap(hours);
      await tester.pump();
      final hourInput = find.byKey(const ValueKey('time-hour-input'));
      await tester.enterText(hourInput, '29');
      await tester.pump();
      expect(tester.widget<ChoiceChip>(hours).selected, isTrue);
      expect(time.hour, 6);
      await tester.enterText(hourInput, '23');
      await tester.pump();
      expect(time.hour, 23);
      expect(tester.widget<ChoiceChip>(minutes).selected, isTrue);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('time-minute-input')))
            .focusNode!
            .hasFocus,
        isTrue,
      );
    },
  );

  test('random mixes never require unconfigured hardware tasks', () {
    for (final difficulty in ChallengeDifficulty.values) {
      for (var seed = 0; seed < 200; seed++) {
        final session = ChallengeSession(
          kind: ChallengeKind.mixed,
          difficulty: difficulty,
          random: Random(seed),
        );
        expect(session.rounds, isNot(contains(ChallengeKind.qr)));
        expect(session.rounds, isNot(contains(ChallengeKind.shake)));
        expect(session.rounds, isNot(contains(ChallengeKind.maze)));
      }
    }
  });

  for (final qrValue in ['', 'registered-qr']) {
    testWidgets(
      'custom QR mix ${qrValue.isEmpty ? 'cannot save without registration' : 'preserves its registered code and order'}',
      (tester) async {
        final gateway = FakeAlarmGateway();
        final controller = AlarmController(
          gateway: gateway,
          storage: MemoryAlarmStorage(),
        );
        addTearDown(controller.dispose);
        await controller.initialize(startPolling: false);
        final alarm = Alarm(
          id: 'qr-mix',
          hour: 7,
          minute: 30,
          challengeKind: ChallengeKind.mixed,
          mixOrder: const [ChallengeKind.qr, ChallengeKind.math],
          qrValue: qrValue,
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: fiveMoreTheme(),
            home: AlarmEditor(controller: controller, alarm: alarm),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('save-alarm')));
        await tester.pumpAndSettle();
        if (qrValue.isEmpty) {
          expect(find.text('Сначала зарегистрируй QR-код.'), findsOneWidget);
          expect(gateway.scheduleCalls, isEmpty);
        } else {
          expect(gateway.scheduleCalls.single.qrValue, qrValue);
          expect(gateway.scheduleCalls.single.mixOrder, [
            ChallengeKind.qr,
            ChallengeKind.math,
          ]);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('alarm title can be saved with advanced settings collapsed', (
    tester,
  ) async {
    final gateway = FakeAlarmGateway();
    final controller = AlarmController(
      gateway: gateway,
      storage: MemoryAlarmStorage(),
    );
    addTearDown(controller.dispose);
    await controller.initialize(startPolling: false);
    await tester.pumpWidget(
      MaterialApp(
        theme: fiveMoreTheme(),
        home: AlarmEditor(controller: controller),
      ),
    );
    final title = find.byKey(const ValueKey('alarm-title'));
    await tester.scrollUntilVisible(
      title,
      350,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(title);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('practice-alarm')), findsNothing);
    await tester.enterText(title, 'Прогулка');
    await tester.tap(find.byKey(const ValueKey('save-alarm')));
    await tester.pumpAndSettle();
    expect(gateway.scheduleCalls.single.title, 'Прогулка');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final finishByLeaving in [false, true]) {
    testWidgets(
      'voice recording runs beyond 30 seconds and saves on ${finishByLeaving ? 'leaving' : 'request'}',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        var stops = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeExtras.channel, (call) async {
              if (call.method == 'stopRecording') {
                stops++;
                return {'file': 'long-note.m4a', 'seconds': 95};
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(NativeExtras.channel, null),
        );
        final journal = SleepJournal()..ready = true;
        addTearDown(journal.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: fiveMoreTheme(),
            home: Scaffold(body: BedtimeScreen(journal: journal)),
          ),
        );
        final record = find.byKey(const ValueKey('record-morning-note'));
        await tester.tap(record);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 95));
        expect(stops, 0);
        expect(find.text('Сохранить · 1:35'), findsOneWidget);
        if (finishByLeaving) {
          await tester.pumpWidget(const SizedBox.shrink());
        } else {
          await tester.tap(record);
        }
        for (
          var attempt = 0;
          attempt < 20 && journal.notes.isEmpty;
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();
        expect(stops, 1);
        expect(journal.notes.single.seconds, 95);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(stops, 1);
      },
    );
  }
}
