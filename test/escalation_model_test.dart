import 'dart:convert';

import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/features/challenges/challenge_models.dart';
import 'package:five_more/models/alarm.dart';
import 'package:five_more/services/alarm_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'alarm_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const gentle = Alarm(
    id: 'morning',
    hour: 7,
    minute: 30,
    difficulty: ChallengeDifficulty.easy,
    escalateOnSnooze: true,
  );

  test(
    'new alarms start gently and disclose escalation in their configuration',
    () {
      final alarm = Alarm.fresh();
      expect(alarm.difficulty, ChallengeDifficulty.easy);
      expect(alarm.escalateOnSnooze, isTrue);
      expect(alarm.difficultyForSnoozes(0), ChallengeDifficulty.easy);
      expect(alarm.difficultyForSnoozes(1), ChallengeDifficulty.medium);
      expect(alarm.difficultyForSnoozes(2), ChallengeDifficulty.hard);
    },
  );

  test(
    'escalation is bounded, monotonic and never mutates the saved baseline',
    () {
      for (final baseline in ChallengeDifficulty.values) {
        final alarm = gentle.copyWith(difficulty: baseline);
        var previous = baseline.index;
        for (var used = 0; used <= 12; used++) {
          final level = alarm.difficultyForSnoozes(used);
          expect(level.index, greaterThanOrEqualTo(previous));
          expect(
            level.index,
            lessThanOrEqualTo(ChallengeDifficulty.extreme.index),
          );
          previous = level.index;
        }
        expect(alarm.difficultyForSnoozes(-1), baseline);
        expect(
          alarm.difficultyForSnoozes(1000000),
          ChallengeDifficulty.extreme,
        );
        expect(alarm.difficulty, baseline);
        expect(Alarm.fromJson(alarm.toJson()).difficulty, baseline);
      }
    },
  );

  test(
    'switching escalation off keeps the selected level after every snooze',
    () {
      for (final baseline in ChallengeDifficulty.values) {
        final alarm = gentle.copyWith(
          difficulty: baseline,
          escalateOnSnooze: false,
        );
        for (final used in [-1, 0, 1, 2, 3, 10]) {
          expect(alarm.difficultyForSnoozes(used), baseline);
        }
        expect(Alarm.fromJson(alarm.toJson()).escalateOnSnooze, isFalse);
      }
    },
  );

  test(
    'old and malformed optional values cannot silently enable escalation',
    () {
      final json = gentle.toJson()..remove('escalateOnSnooze');
      for (final value in [null, 'true', 1, [], {}]) {
        final alarm = Alarm.fromJson({...json, 'escalateOnSnooze': ?value});
        expect(alarm.escalateOnSnooze, isFalse);
        expect(alarm.difficultyForSnoozes(3), ChallengeDifficulty.easy);
      }
    },
  );

  test(
    'v0.2 storage retains alarms and history without opting existing alarms in',
    () async {
      final oldAlarm = gentle.toJson()..remove('escalateOnSnooze');
      final event = AlarmEvent(
        eventId: 'old-event',
        alarmId: gentle.id,
        occurrenceId: 'yesterday',
        type: 'snoozed',
        at: DateTime(2026, 10, 22, 7, 30),
        snoozesUsed: 1,
      );
      SharedPreferences.setMockInitialValues({
        'five_more.state.v1': jsonEncode({
          'version': 2,
          'alarms': [oldAlarm],
          'events': [event.toJson()],
        }),
      });
      final storage = LocalAlarmStorage();
      final before = await storage.load();
      expect(before.alarms.single.escalateOnSnooze, isFalse);
      expect(
        before.alarms.single.difficultyForSnoozes(3),
        ChallengeDifficulty.easy,
      );
      expect(before.events.single.toJson(), event.toJson());
      await storage.save(before);
      final after = await LocalAlarmStorage().load();
      expect(after.alarms.single.toJson(), before.alarms.single.toJson());
      expect(after.events.single.toJson(), event.toJson());
    },
  );

  test('native occurrence restores level after reopening and resets it next morning', () async {
    final gateway = FakeAlarmGateway();
    final storage = MemoryAlarmStorage()
      ..snapshot = AlarmSnapshot(alarms: [Alarm.fromJson(gentle.toJson())]);
    gateway.nativeAlarms[gentle.id] = Alarm.fromJson(gentle.toJson());
    RingingAlarm nativeRing(String occurrence, int snoozes) =>
        RingingAlarm.fromJson({
          'alarm': gentle.toJson(),
          'occurrenceId': occurrence,
          'firedAt': DateTime(2026, 10, 22, 7, 40).millisecondsSinceEpoch,
          'snoozesUsed': snoozes,
        });
    gateway.ringing = nativeRing('today', 2);
    final first = AlarmController(gateway: gateway, storage: storage);
    await first.initialize(startPolling: false);
    expect(first.ringing!.challengeDifficulty, ChallengeDifficulty.hard);
    first.dispose();

    final reopened = AlarmController(gateway: gateway, storage: storage);
    addTearDown(reopened.dispose);
    await reopened.initialize(startPolling: false);
    expect(reopened.ringing!.snoozesUsed, 2);
    expect(reopened.ringing!.challengeDifficulty, ChallengeDifficulty.hard);
    expect(reopened.ringing!.alarm.difficulty, ChallengeDifficulty.easy);
    expect(gateway.scheduleCalls, isEmpty);

    gateway.ringing = nativeRing('tomorrow', 0);
    await reopened.poll();
    expect(reopened.ringing!.occurrenceId, 'tomorrow');
    expect(reopened.ringing!.challengeDifficulty, ChallengeDifficulty.easy);
    expect(gateway.dismissCalls, isEmpty);
  });
}
