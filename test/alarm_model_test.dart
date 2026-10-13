import 'package:five_more/features/challenges/challenge_models.dart';
import 'package:five_more/models/alarm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Wall-clock scheduling', () {
    const weekdays = Alarm(
      id: 'weekday',
      hour: 7,
      minute: 30,
      weekdays: [1, 2, 3, 4, 5],
    );
    test('a Friday alarm after its time selects Monday', () {
      expect(
        weekdays.nextOccurrence(DateTime(2026, 10, 16, 7, 31)),
        DateTime(2026, 10, 19, 7, 30),
      );
    });
    test('at the exact selected minute the next future occurrence is used', () {
      expect(
        weekdays.nextOccurrence(DateTime(2026, 10, 13, 7, 30)),
        DateTime(2026, 10, 14, 7, 30),
      );
    });
    test('one-shot chooses today before the selected time', () {
      const once = Alarm(id: 'once', hour: 7, minute: 30);
      expect(
        once.nextOccurrence(DateTime(2026, 10, 13, 6)),
        DateTime(2026, 10, 13, 7, 30),
      );
      expect(
        once.nextOccurrence(DateTime(2026, 10, 13, 8)),
        DateTime(2026, 10, 14, 7, 30),
      );
    });
  });

  test('native zero nextAt means no pending occurrence', () {
    final alarm = Alarm.fromJson({
      'id': 'a',
      'hour': 7,
      'minute': 0,
      'nextAt': 0,
    });
    expect(alarm.nextAt, isNull);
  });

  test(
    'round-trip retains challenge, repeat days, budget and native due time',
    () {
      final original = Alarm(
        id: 'round-trip',
        hour: 9,
        minute: 15,
        title: 'Прогулка',
        weekdays: const [6, 7],
        snoozeMinutes: 10,
        maxSnoozes: 1,
        challengeKind: ChallengeKind.mixed,
        difficulty: ChallengeDifficulty.hard,
        nextAt: DateTime(2026, 10, 17, 9, 15),
      );
      expect(Alarm.fromJson(original.toJson()).toJson(), original.toJson());
    },
  );

  test(
    'malformed persisted limits and weekdays cannot create invalid settings',
    () {
      final alarm = Alarm.fromJson({
        'id': 'bad',
        'hour': 88,
        'minute': -3,
        'weekdays': [0, 1, 1, 3, 8],
        'snoozeMinutes': 500,
        'maxSnoozes': -1,
        'challengeKind': 'future-kind',
        'difficulty': 'future-level',
      });
      expect(alarm.hour, 23);
      expect(alarm.minute, 0);
      expect(alarm.weekdays, [1, 3]);
      expect(alarm.maxSnoozes, 0);
      expect(alarm.challengeKind, ChallengeKind.math);
    },
  );

  test('reopened ringing session retains native snooze budget', () {
    final ring = RingingAlarm.fromJson({
      ...const Alarm(id: 'a', hour: 7, minute: 0, maxSnoozes: 3).toJson(),
      'occurrenceId': 'occurrence',
      'snoozesUsed': 3,
    });
    expect(ring.snoozesRemaining, 0);
  });

  test('IDs are native-compatible UUID v4 values', () {
    final ids = List.generate(100, (_) => newAlarmId());
    final pattern = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    );
    expect(ids.every((id) => pattern.hasMatch(id)), isTrue);
    expect(ids.toSet(), hasLength(100));
  });
}
