import 'dart:math';
import 'dart:convert';
import 'dart:async';

import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/features/challenges/challenge_models.dart';
import 'package:five_more/features/challenges/physical_tasks.dart';
import 'package:five_more/features/history/history_view.dart';
import 'package:five_more/models/alarm.dart';
import 'package:five_more/models/sleep_entry.dart';
import 'package:five_more/services/phrase_library.dart';
import 'package:five_more/services/sleep_journal.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'alarm_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'nap absolute time, exact mix order, QR and sound survive round trip',
    () {
      final now = DateTime(2026, 10, 27, 23, 58);
      final due = now.add(const Duration(minutes: 20));
      final alarm = Alarm(
        id: 'nap',
        hour: due.hour,
        minute: due.minute,
        oneShotAt: due,
        challengeKind: ChallengeKind.mixed,
        mixOrder: const [
          ChallengeKind.qr,
          ChallengeKind.math,
          ChallengeKind.qr,
        ],
        qrValue: 'kitchen-code',
        sound: 'arcade',
        difficulty: ChallengeDifficulty.extreme,
      );
      final restored = Alarm.fromJson(alarm.toJson());
      expect(restored.nextOccurrence(now), DateTime(2026, 10, 28, 0, 18));
      expect(restored.toJson(), alarm.toJson());
      final session = ChallengeSession(
        kind: restored.challengeKind,
        difficulty: restored.difficulty,
        order: restored.mixOrder,
      );
      expect(session.rounds, [
        ChallengeKind.qr,
        ChallengeKind.math,
        ChallengeKind.qr,
      ]);
      session.submitCorrect();
      session.submitCorrect();
      session.submitIncorrect();
      expect(session.completedSteps, 1);
      expect(session.currentKind, ChallengeKind.math);
      session.submitIncorrect();
      session.submitIncorrect();
      expect(session.completedSteps, 0);
    },
  );

  test(
    'more than 500 events are persisted before native acknowledgement',
    () async {
      final gateway = FakeAlarmGateway();
      final storage = MemoryAlarmStorage();
      final controller = AlarmController(gateway: gateway, storage: storage);
      addTearDown(controller.dispose);
      gateway.pendingEvents.addAll(
        List.generate(
          800,
          (i) => AlarmEvent(
            eventId: '$i',
            alarmId: 'a',
            occurrenceId: 'o$i',
            type: 'fired',
            at: DateTime(2026, 1, 1).add(Duration(minutes: i)),
          ),
        ),
      );
      gateway.beforeAck = (_) =>
          expect(storage.snapshot.events, hasLength(800));
      await controller.initialize(startPolling: false);
      expect(controller.events, hasLength(800));
      expect(gateway.acknowledged, hasLength(800));
      final reopened = AlarmController(gateway: gateway, storage: storage);
      addTearDown(reopened.dispose);
      await reopened.initialize(startPolling: false);
      expect(reopened.events, hasLength(800));
    },
  );

  test('stats count occurrences, distinguish emergency, ignore preview', () {
    final now = DateTime(2026, 10, 27, 7);
    AlarmEvent event(
      String id,
      String type,
      int minute, {
      String alarm = 'a',
    }) => AlarmEvent(
      eventId: '$id$type$minute',
      alarmId: alarm,
      occurrenceId: id,
      type: type,
      at: now.add(Duration(minutes: minute)),
    );
    final stats = MorningStats([
      event('1', 'fired', 0),
      event('1', 'snoozed', 1),
      event('1', 'fired', 6),
      event('1', 'dismissed', 9),
      event('2', 'emergency_dismissed', 10),
      event('3', 'missed', 11),
      event('4', 'dismissed', 12, alarm: 'preview:x'),
    ]);
    expect(stats.outcomes, [1, 1, 1]);
    expect(stats.wakeMinutes.single.value, 9);
  });

  test('sleep insight requires repeated observations in competing ranges', () {
    SleepEntry entry(int day, int hours, int score) {
      final at = DateTime(2026, 10, day, 8);
      return SleepEntry(
        occurrenceId: '$day',
        wokeAt: at,
        bedAt: at.subtract(Duration(hours: hours)),
        sleepQuality: score,
        wakeQuality: score,
      );
    }

    final entries = [
      entry(1, 7, 2),
      entry(2, 7, 3),
      entry(3, 7, 2),
      entry(4, 8, 5),
      entry(5, 8, 4),
      entry(6, 8, 5),
      entry(7, 6, 1),
    ];
    expect(SleepInsight.fromEntries(entries.take(6).toList()), isNull);
    expect(SleepInsight.fromEntries(entries)!.hours, 8);
    expect(SleepInsight.fromEntries(entries)!.samples, 3);
  });

  test('denied reminder is never saved as enabled', () async {
    const channel = MethodChannel('five_more/extras');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => throw PlatformException(code: 'denied'),
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final journal = SleepJournal();
    addTearDown(journal.dispose);
    await journal.load();
    await expectLater(
      journal.configureReminder(true, 23, 15),
      throwsA(isA<PlatformException>()),
    );
    expect(journal.reminder, isFalse);
    final reopened = SleepJournal();
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.reminder, isFalse);
  });

  test(
    'phrases make no requests without consent; bad source keeps fallback',
    () async {
      final library = PhraseLibrary();
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response('bad', 503);
      });
      expect(await library.refresh(client: client), 0);
      expect(requests, 0);
      await library.setEnabled(true);
      await expectLater(library.refresh(client: client), throwsStateError);
      final phrases = List.generate(
        4,
        (i) => library.next(Random(i), ChallengeDifficulty.hard).text,
      );
      expect(phrases.toSet(), hasLength(4));
      expect(PhraseLibrary.sanitize('<script>x</script>'), isNull);
      expect(PhraseLibrary.sanitize('а' * 141), isNull);
    },
  );

  test(
    'successful phrase refresh persists, deduplicates and is limited to daily',
    () async {
      var requests = 0;
      final client = MockClient((request) async {
        expect(request.url.scheme, 'https');
        expect(request.body, isEmpty);
        requests++;
        return http.Response(
          jsonEncode({
            'quoteText':
                'Каждое утро даёт возможность сделать новый шаг вперёд.',
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final library = PhraseLibrary();
      await library.load();
      await library.setEnabled(true);
      expect(await library.refresh(client: client), 1);
      expect(requests, 6);
      final restored = PhraseLibrary();
      await restored.load();
      expect(restored.phrases, library.phrases);
      expect(await restored.refresh(client: client), 0);
      expect(requests, 6);
    },
  );

  test(
    'an alarm or revoked consent stops a phrase batch before the next request',
    () async {
      for (final ringing in [false, true]) {
        final library = PhraseLibrary();
        await library.load();
        await library.setEnabled(true);
        final received = Completer<void>(), reply = Completer<http.Response>();
        var requests = 0;
        final client = MockClient((_) {
          requests++;
          received.complete();
          return reply.future;
        });
        final refresh = library.refresh(client: client);
        await received.future;
        if (ringing) {
          library.setAlarmRinging(true);
        } else {
          await library.setEnabled(false);
        }
        reply.complete(
          http.Response(
            jsonEncode({
              'quoteText':
                  'Каждое утро даёт возможность сделать новый шаг вперёд.',
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        );
        expect(await refresh, 0);
        expect(requests, 1);
        expect(library.phrases, isEmpty);
      }
    },
  );

  test(
    'hard sequence moves remaining numbers while retaining solved cells',
    () {
      var board = generateSequenceBoard(Random(3), ChallengeDifficulty.hard);
      for (var completed = 1; completed < board.cellCount - 1; completed++) {
        final next = board.reshuffleRemaining(Random(completed), completed);
        for (var n = 1; n <= completed; n++) {
          expect(next.numbers.indexOf(n), board.numbers.indexOf(n));
        }
        expect(
          next.numbers.where((n) => n > completed),
          isNot(orderedEquals(board.numbers.where((n) => n > completed))),
        );
        board = next;
      }
    },
  );

  test(
    'shake needs alternating movement and rejects noisy or duplicate samples',
    () {
      final counter = ShakeCounter(12);
      for (var i = 0; i < 20; i++) {
        counter.add(0, 0, 1, Duration(milliseconds: i * 200));
      }
      expect(counter.count, 0);
      counter.add(12, 0, 0, const Duration(seconds: 5));
      for (var i = 0; i < 10; i++) {
        counter.add(12, 0, 0, Duration(milliseconds: 5200 + i * 200));
      }
      expect(counter.count, 1);
      for (var i = 0; i < 20; i++) {
        counter.add(
          i.isEven ? -14 : 14,
          0,
          0,
          Duration(milliseconds: 7500 + i * 200),
        );
      }
      expect(counter.count, 12);
    },
  );

  test('maze walls prevent tunnelling and a hole resets the ball', () {
    final maze = TiltMaze(ChallengeDifficulty.hard);
    for (var i = 0; i < 200; i++) {
      maze.step(const Offset(100, 0), .2);
    }
    expect(maze.ball.dx, lessThan(.24));
    maze.ball = maze.holes.first;
    expect(maze.step(Offset.zero, .02), -1);
    expect(maze.ball, maze.start);
    maze.ball = maze.goal;
    expect(maze.step(Offset.zero, .02), 1);
  });
}
