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
}
