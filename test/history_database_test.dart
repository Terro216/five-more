import 'dart:convert';

import 'package:five_more/features/history/history_view.dart';
import 'package:five_more/models/alarm.dart';
import 'package:five_more/models/sleep_session.dart';
import 'package:five_more/services/alarm_storage.dart';
import 'package:five_more/services/local_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final morning = DateTime(2026, 10, 29, 7);
  AlarmEvent event(
    String id,
    String type,
    DateTime at, {
    String occurrence = 'wake',
    DateTime? nextAt,
  }) => AlarmEvent(
    eventId: id,
    alarmId: 'alarm',
    occurrenceId: occurrence,
    type: type,
    at: at,
    nextAt: nextAt,
  );

  test(
    'legacy migration keeps full archive, only recent 500 load into controller',
    () async {
      final events = List.generate(
        800,
        (i) => event('$i', 'fired', morning.add(Duration(minutes: i))).toJson(),
      );
      final legacy = jsonEncode({
        'alarms': [const Alarm(id: 'alarm', hour: 7, minute: 0).toJson()],
        'events': events,
      });
      await LocalDatabase.instance.close();
      LocalDatabase.instance = LocalDatabase(path: ':memory:');
      SharedPreferences.setMockInitialValues({'five_more.state.v1': legacy});
      final storage = LocalAlarmStorage();
      final snapshot = await storage.load();
      expect(snapshot.events, hasLength(500));
      expect(snapshot.alarms.single.id, 'alarm');
      expect(await LocalDatabase.instance.records('event'), hasLength(800));
      await storage.save(snapshot);
      expect(await LocalDatabase.instance.records('event'), hasLength(800));
      expect(
        (await SharedPreferences.getInstance()).getString('five_more.state.v1'),
        legacy,
      );
    },
  );

  test('corrupt legacy data is not marked migrated or overwritten', () async {
    await LocalDatabase.instance.close();
    LocalDatabase.instance = LocalDatabase(path: ':memory:');
    SharedPreferences.setMockInitialValues({'five_more.state.v1': '{broken'});
    await expectLater(LocalDatabase.instance.database, throwsFormatException);
    expect(
      (await SharedPreferences.getInstance()).getString('five_more.state.v1'),
      '{broken',
    );
  });

  test(
    'acknowledging an older upload preserves an edit made during upload',
    () async {
      final db = LocalDatabase.instance;
      await db.put('sleep', 'night', {'value': 1}, 1);
      final sent = (await db.pending()).single;
      await db.put('sleep', 'night', {'value': 2}, 1);
      await db.acknowledge(sent, 1);
      final pending = (await db.pending()).single;
      expect(pending['revision'], 1);
      expect(jsonDecode(pending['data'] as String), {'value': 2});
      expect(
        await db.receive({
          'kind': 'sleep',
          'id': 'night',
          'data': {'value': 3},
          'at': 1,
          'revision': 2,
          'deleted': false,
        }),
        isFalse,
      );
      await db.acknowledge(pending, 2);
      expect(await db.pending(), isEmpty);
    },
  );

  test('audio consent gates notes, but revocation does not prevent deleting an uploaded note', () async {
    final db = LocalDatabase.instance;
    await db.put('note', 'voice', {'file': 'voice'}, 1);
    expect(await db.pending(), isEmpty);
    final sent = (await db.pending(audio: true)).single;
    await db.acknowledge(sent, 1);
    await db.remove('note', 'voice');
    expect((await db.pending()).single['deleted'], 1);
    expect(await db.records('note'), isEmpty);
    expect(await db.isDeleted('note', 'voice'), isTrue);
  });

  test(
    'server pages are not queued as local events and preview IDs stay local',
    () async {
      final db = LocalDatabase.instance;
      final data = event('remote', 'fired', morning).toJson();
      await db.receive({
        'kind': 'event',
        'id': 'remote',
        'data': data,
        'at': morning.millisecondsSinceEpoch,
        'revision': 1,
        'deleted': false,
      });
      await db.saveAlarmState({}, [
        {...data, 'id': 'preview:temporary', 'eventId': 'test'},
      ]);
      expect(await db.pending(), isEmpty);
      expect(await db.records('event'), hasLength(1));
    },
  );

  test('period outcomes include a ring begun just before the boundary', () {
    final stats = MorningStats(
      [
        event('start', 'fired', morning.subtract(const Duration(minutes: 5))),
        event('end', 'dismissed', morning.add(const Duration(minutes: 3))),
      ],
      from: morning,
      until: morning.add(const Duration(days: 1)),
    );
    expect(stats.outcomes, [1, 0, 0]);
    expect(stats.wakeMinutes.single.value, 8);
  });

  test('rearming shortly after dismissal joins the night; explicit separation wins', () {
    final events = [
      event('evening', 'armed', DateTime(2026, 10, 28, 23)),
      event('start', 'fired', morning),
      event('end', 'dismissed', morning.add(const Duration(minutes: 2))),
      event(
        'again',
        'armed',
        morning.add(const Duration(minutes: 4)),
        occurrence: 'setup',
        nextAt: morning.add(const Duration(minutes: 30)),
      ),
      event(
        'start2',
        'fired',
        morning.add(const Duration(minutes: 30)),
        occurrence: 'wake2',
      ),
      event(
        'end2',
        'dismissed',
        morning.add(const Duration(minutes: 32)),
        occurrence: 'wake2',
      ),
    ];
    final session = SleepSession.fromEvents(events).single;
    expect(session.occurrences, ['wake', 'wake2']);
    expect(session.lastEvent.at, morning.add(const Duration(minutes: 32)));
    expect(session.bedtimeCandidate, DateTime(2026, 10, 28, 23));
    expect(
      SleepSession.fromEvents(events, separateOccurrences: {'wake2'}),
      hasLength(2),
    );
    expect(
      SleepSession.fromEvents(
        events.where((e) => e.eventId != 'again').toList(),
      ),
      hasLength(2),
    );
  });
}
