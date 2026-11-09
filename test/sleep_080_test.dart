import 'dart:io';

import 'package:five_more/models/alarm.dart';
import 'package:five_more/models/sleep_session.dart';
import 'package:five_more/models/sleep_goals.dart';
import 'package:five_more/models/sleep_entry.dart';
import 'package:five_more/services/sleep_journal.dart';
import 'package:five_more/services/local_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

AlarmEvent e(
  String id,
  String alarm,
  String occurrence,
  String type,
  DateTime time, {
  DateTime? due,
}) => AlarmEvent(
  eventId: id,
  alarmId: alarm,
  occurrenceId: occurrence,
  type: type,
  at: time,
  nextAt: due,
);

void main() {
  test(
    'bedtime uses a fresh matching alarm setup even for short daytime sleep',
    () {
      final start = DateTime(2026, 11, 10, 15);
      final session = SleepSession.fromEvents([
        e(
          'own',
          'a',
          'setup',
          'armed',
          start.subtract(const Duration(minutes: 40)),
          due: start,
        ),
        e(
          'other',
          'b',
          'setup2',
          'armed',
          start.subtract(const Duration(minutes: 30)),
          due: start,
        ),
        e('ring', 'a', 'wake', 'fired', start),
        e(
          'end',
          'a',
          'wake',
          'dismissed',
          start.add(const Duration(minutes: 5)),
        ),
      ]).single;
      expect(
        session.bedtimeCandidate,
        start.subtract(const Duration(minutes: 40)),
      );
    },
  );
  test('prepared alarms share final wake boundary; explicit split and later nap stay separate', () {
    final morning = DateTime(2026, 11, 10, 7);
    final events = [
      e(
        'setup',
        'a',
        'setup',
        'armed',
        DateTime(2026, 11, 9, 23),
        due: morning,
      ),
      e('a', 'a', 'one', 'fired', morning),
      e('b', 'a', 'one', 'dismissed', morning.add(const Duration(minutes: 5))),
      e('c', 'b', 'two', 'fired', morning.add(const Duration(minutes: 30))),
      e('d', 'b', 'two', 'dismissed', morning.add(const Duration(minutes: 35))),
    ];
    final joined = SleepSession.fromEvents(events).single;
    expect(joined.occurrences, ['one', 'two']);
    expect(joined.lastEvent.at, morning.add(const Duration(minutes: 35)));
    expect(
      SleepSession.fromEvents(events, separateOccurrences: {'two'}),
      hasLength(2),
    );
    events.addAll([
      e(
        'napset',
        'c',
        'napsetup',
        'armed',
        morning.add(const Duration(hours: 5)),
      ),
      e('nap', 'c', 'nap', 'dismissed', morning.add(const Duration(hours: 6))),
    ]);
    expect(SleepSession.fromEvents(events), hasLength(2));
  });
  test('week-old setup does not become a fresh bedtime', () {
    final now = DateTime(2026, 11, 10, 7);
    expect(
      SleepSession.fromEvents([
        e('old', 'a', 'setup', 'armed', now.subtract(const Duration(days: 7))),
        e('end', 'a', 'wake', 'dismissed', now),
      ]).single.bedtimeCandidate,
      isNull,
    );
  });
  test('regularity wraps midnight and duration respects time zone offsets', () {
    expect(SleepGoals.clockDistance(23 * 60 + 50, 10), 20);
    expect(SleepGoals.clockDistance(10, 23 * 60 + 50), 20);
    const goals = SleepGoals(durationMinutes: 450);
    expect(goals.hasSchedule, isFalse);
    expect(SleepGoals.fromJson({}).isEmpty, isTrue);
    final entry = SleepEntry(
      occurrenceId: 'dst',
      bedAt: DateTime.parse('2026-10-25T00:00:00+02:00'),
      wokeAt: DateTime.parse('2026-10-25T08:00:00+01:00'),
      sleepQuality: 3,
      wakeQuality: 3,
    );
    expect(entry.hours, 9);
    // The saved endpoints use different offsets across a DST transition, and
    // neither changes if the phone subsequently travels to another zone.
    expect(SleepGoals.wallTime(entry.bedAt, 120).hour, 0);
    expect(SleepGoals.wallTime(entry.wokeAt, 60).hour, 8);
  });
  test('goals and original estimates stay local and survive reload without sync records', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    LocalDatabase.instance = LocalDatabase(path: inMemoryDatabasePath);
    addTearDown(LocalDatabase.instance.close);
    final journal = SleepJournal();
    addTearDown(journal.dispose);
    await journal.load();
    expect(journal.goals.isEmpty, isTrue);
    await journal.setGoals(
      const SleepGoals(
        durationMinutes: 451,
        bedMinute: 1430,
        wakeMinute: 420,
        toleranceMinutes: 25,
      ),
    );
    await journal.saveEstimate('night', {
      'source': 'alarm_setup',
      'fallingAsleepMinutes': 20,
    });
    await journal.saveEstimate('night', {'source': 'manual'});
    final restored = SleepJournal();
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.goals.durationMinutes, 451);
    expect(restored.sleepEstimates['night']['source'], 'alarm_setup');
    expect(await LocalDatabase.instance.pending(), isEmpty);
  });
  test(
    'morning rearming never invents a bedtime when the first setup is unknown',
    () {
      final morning = DateTime(2026, 11, 10, 7);
      final session = SleepSession.fromEvents([
        e('first', 'a', 'one', 'dismissed', morning),
        e(
          'rearm',
          'a',
          'setup',
          'armed',
          morning.add(const Duration(minutes: 2)),
          due: morning.add(const Duration(minutes: 30)),
        ),
        e(
          'again',
          'a',
          'two',
          'dismissed',
          morning.add(const Duration(minutes: 30)),
        ),
      ]).single;
      expect(session.occurrences, ['one', 'two']);
      expect(session.bedtimeCandidate, isNull);
    },
  );

  test('unchanged confirmed times retain saved zones; foreign edits do not inherit stale offsets', () async {
    final journal = SleepJournal()..ready = true;
    addTearDown(journal.dispose);
    final entry = SleepEntry(
      occurrenceId: 'night',
      wokeAt: DateTime.utc(2026, 10, 25, 7),
      bedAt: DateTime.utc(2026, 10, 24, 22),
      sleepQuality: 3,
      wakeQuality: 3,
    );
    await journal.saveEntry(entry);
    journal.sleepTimezones['night'] = {
      'bedAt': entry.bedAt.millisecondsSinceEpoch,
      'bedtimeAt': entry.bedAt.millisecondsSinceEpoch,
      'wakeAt': entry.wokeAt.millisecondsSinceEpoch,
      'bedOffsetMinutes': 120,
      'wakeOffsetMinutes': 60,
    };
    await journal.saveEntry(entry);
    expect(journal.sleepTimezones['night']['bedOffsetMinutes'], 120);
    expect(journal.sleepTimezones['night']['wakeOffsetMinutes'], 60);
    final foreign = SleepEntry(
      occurrenceId: 'night',
      wokeAt: entry.wokeAt.add(const Duration(hours: 1)),
      bedAt: entry.bedAt.add(const Duration(hours: 1)),
      sleepQuality: 4,
      wakeQuality: 4,
    );
    journal.entries = [
      foreign,
    ]; // A received record has no local timezone metadata.
    await journal.saveEntry(foreign);
    expect(journal.sleepTimezones['night']['bedOffsetMinutes'], isNull);
    expect(journal.sleepTimezones['night']['wakeOffsetMinutes'], isNull);
  });
  test(
    'DST boundary uses offset at estimated bedtime',
    () async {
      final journal = SleepJournal()..ready = true;
      addTearDown(journal.dispose);
      // Berlin jumps from 02:00 to 03:00 during this 20-minute interval.
      final asleep = DateTime(2026, 3, 29, 3, 10);
      await journal.saveEstimate('spring', {
        'source': 'alarm_setup',
        'fallingAsleepMinutes': 20,
      });
      final entry = SleepEntry(
        occurrenceId: 'spring',
        bedAt: asleep,
        wokeAt: DateTime(2026, 3, 29, 8),
        sleepQuality: 3,
        wakeQuality: 3,
      );
      await journal.saveEntry(entry);
      final zone = journal.sleepTimezones['spring'];
      expect(zone['bedOffsetMinutes'], 60);
      expect(zone['wakeOffsetMinutes'], 120);
      final bedWall = SleepGoals.wallTime(
        SleepGoals.estimatedBedtime(asleep, 20),
        zone['bedOffsetMinutes'] as int,
      );
      expect([bedWall.hour, bedWall.minute], [1, 50]);
      // Fall-back crosses the repeated hour in the opposite direction.
      final autumnAsleep = DateTime.parse('2026-10-25T02:10:00+01:00')
          .toLocal();
      await journal.saveEstimate('autumn', {
        'source': 'alarm_setup',
        'fallingAsleepMinutes': 20,
      });
      await journal.saveEntry(
        SleepEntry(
          occurrenceId: 'autumn',
          bedAt: autumnAsleep,
          wokeAt: DateTime(2026, 10, 25, 8),
          sleepQuality: 3,
          wakeQuality: 3,
        ),
      );
      final autumnZone = journal.sleepTimezones['autumn'];
      expect(autumnZone['bedOffsetMinutes'], 120);
      expect(autumnZone['wakeOffsetMinutes'], 60);
      final autumnBed = SleepGoals.wallTime(
        SleepGoals.estimatedBedtime(autumnAsleep, 20),
        autumnZone['bedOffsetMinutes'] as int,
      );
      expect([autumnBed.hour, autumnBed.minute], [2, 50]);
    },
    skip:
        Platform.environment['FIVE_MORE_DST_TEST'] != 'true' &&
            (DateTime(2026, 3, 29, 1, 50).timeZoneOffset.inMinutes != 60 ||
                DateTime(2026, 3, 29, 3, 10).timeZoneOffset.inMinutes != 120)
        ? 'Run with TZ=Europe/Berlin (dedicated CI step).'
        : false,
  );
}
