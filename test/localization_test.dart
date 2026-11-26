import 'dart:convert';
import 'dart:math';

import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/app/five_more_app.dart';
import 'package:five_more/features/challenges/challenge_models.dart';
import 'package:five_more/l10n/strings.dart';
import 'package:five_more/models/alarm.dart';
import 'package:five_more/services/phrase_library.dart';
import 'package:five_more/widgets/time_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'alarm_fakes.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final language = AppLanguage.instance;
  tearDown(() => language.value = null);

  testWidgets('system preferences, English fallback and per-app selection', (
    tester,
  ) async {
    final dispatcher = tester.platformDispatcher;
    dispatcher.localesTestValue = const [Locale('es'), Locale('ru')];
    expect(language.effective, const Locale('ru'));
    dispatcher.localesTestValue = const [Locale('fr')];
    const channel = MethodChannel('five_more/language');
    const extras = MethodChannel('five_more/extras');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      extras,
      (call) async => call.method == 'version' ? '1.0' : null,
    );
    addTearDown(
      () =>
          binding.defaultBinaryMessenger.setMockMethodCallHandler(extras, null),
    );
    String? stored;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'set') stored = call.arguments as String;
      return stored;
    });
    addTearDown(
      () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final gateway = FakeAlarmGateway()..supported = false;
    final controller = AlarmController(
      gateway: gateway,
      storage: MemoryAlarmStorage(),
    );
    await controller.initialize(startPolling: false);
    await tester.pumpWidget(FiveMoreApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('Challenges'), findsOneWidget);
    await tester.tap(find.byTooltip('About'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('System default'));
    await tester.tap(find.text('System default'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Русский').last);
    await tester.pumpAndSettle();
    expect(find.text('Понятно'), findsOneWidget);
    expect(stored, 'ru');
    language.value = null;
    await language.load();
    expect(language.effective, const Locale('ru'));
    await tester.tap(find.text('Понятно'));
    await tester.pumpAndSettle();
    expect(find.text('Задания'), findsOneWidget);
    await language.select(null);
    await tester.pumpAndSettle();
    expect(find.text('Challenges'), findsOneWidget);
    expect(gateway.scheduleCalls, isEmpty);
    expect(gateway.cancelCalls, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('changing system language keeps the active wake-up challenge', (
    tester,
  ) async {
    final gateway = FakeAlarmGateway();
    final controller = AlarmController(
      gateway: gateway,
      storage: MemoryAlarmStorage(),
    );
    await controller.initialize(startPolling: false);
    await tester.pumpWidget(FiveMoreApp(controller: controller));
    gateway.ringing = RingingAlarm(
      alarm: const Alarm(
        id: 'morning',
        hour: 7,
        minute: 30,
        challengeKind: ChallengeKind.mirror,
      ),
      occurrenceId: 'morning-occurrence',
      snoozesUsed: 2,
      firedAt: DateTime(2026, 11, 25, 7, 30),
    );
    await controller.poll();
    await tester.pumpAndSettle();
    final challenge = find.byKey(const ValueKey('ringing-start-challenge'));
    await tester.ensureVisible(challenge);
    await tester.tap(challenge);
    await tester.pumpAndSettle();
    final input = find.byType(TextField);
    expect(tester.widget<TextField>(input).decoration?.labelText, 'Ответ');
    tester.platformDispatcher.localesTestValue = const [Locale('en', 'US')];
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).decoration?.labelText, 'Answer');
    expect(find.text('Trouble with the challenge'), findsOneWidget);
    expect(controller.ringing?.occurrenceId, 'morning-occurrence');
    expect(controller.ringing?.snoozesUsed, 2);
    expect(gateway.dismissCalls, isEmpty);
    expect(gateway.scheduleCalls, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('12-hour editor distinguishes noon and midnight', (tester) async {
    language.value = const Locale('en');
    tester.platformDispatcher.localesTestValue = const [Locale('en', 'US')];
    var time = const TimeOfDay(hour: 0, minute: 15);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, rebuild) => TimeComposer(
              time: time,
              onChanged: (value) => rebuild(() => time = value),
            ),
          ),
        ),
      ),
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('time-hour-input')))
          .controller!
          .text,
      '12',
    );
    await tester.tap(find.text('PM'));
    await tester.pump();
    expect(time.hour, 12);
    await tester.enterText(find.byKey(const ValueKey('time-hour-input')), '1');
    expect(time.hour, 13);
    await tester.tap(find.text('AM'));
    await tester.pump();
    expect(time.hour, 1);
    expect(time.minute, 15);
    expect(appClock(13, 15), contains('PM'));
    tester.platformDispatcher.alwaysUse24HourFormatTestValue = true;
    expect(appClock(13, 15), '13:15');
    tester.platformDispatcher.clearAlwaysUse24HourTestValue();
  });

  test('English mirror challenges work offline and keep quote caches separate', () async {
    language.value = const Locale('en');
    final library = PhraseLibrary(browser: true);
    await library.load();
    for (final difficulty in ChallengeDifficulty.values) {
      final question = library.next(Random(2), difficulty);
      expect(question.text, matches(RegExp(r'^[a-zA-Z ]+$')));
      expect(question.accepts(question.text.toUpperCase()), isTrue);
    }
    await library.setEnabled(true);
    const quote = 'Today is a good day to begin';
    final client = MockClient((request) async {
      expect(request.url.host, 'en.wikiquote.org');
      return http.Response(
        jsonEncode({
          'parse': {
            'revid': 19,
            'text':
                '<h2>Quotes</h2><ul><li>$quote<ul><li>Editorial source detail</li></ul></li></ul><h2>Misattributed</h2><ul><li>Other words to exclude</li></ul>',
          },
        }),
        200,
      );
    });
    expect((await library.refresh(client: client)).added, 1);
    final reopened = PhraseLibrary(browser: true);
    await reopened.load();
    expect(reopened.next(Random(1), ChallengeDifficulty.medium).text, quote);
    language.value = const Locale('ru');
    expect(reopened.availableCount, 0);
    language.value = const Locale('en');
    expect(reopened.availableCount, 1);
    const name = 'Мой будильник';
    final alarm = Alarm.fresh().copyWith(title: name);
    expect(Alarm.fromJson(alarm.toJson()).systemTitle, name);
  });
}
