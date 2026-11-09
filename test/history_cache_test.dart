import 'dart:async';
import 'dart:convert';

import 'package:five_more/features/history/history_view.dart';
import 'package:five_more/services/local_database.dart';
import 'package:five_more/services/sleep_journal.dart';
import 'package:five_more/services/sync_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _from = DateTime(2026, 11, 1), _until = DateTime(2026, 11, 11);
final _summary = {
  'snoozes': 0,
  'outcomes': [0, 0, 0],
  'snoozeDays': [],
  'wakeDays': [],
  'sleepDays': [],
};
final _event = {
  'eventId': 'event',
  'id': 'alarm',
  'occurrenceId': 'wake',
  'type': 'fired',
  'at': _from.millisecondsSinceEpoch,
};
final _record = {
  'kind': 'event',
  'id': 'event',
  'data': _event,
  'at': _from.millisecondsSinceEpoch,
  'revision': 1,
  'deleted': false,
};
http.Response _response(Object data, [int status = 200]) => http.Response(
  jsonEncode(data),
  status,
  headers: {'content-type': 'application/json'},
);

Future<SyncService> _service(
  Future<http.Response> Function(http.Request) handler, {
  DateTime Function()? now,
}) async {
  FlutterSecureStorage.setMockInitialValues({
    'five_more_sync_session': jsonEncode({
      'endpoint': 'https://sync.example.test',
      'token': 'test-session',
      'accountId': 'account',
      'sessionId': 'session',
    }),
  });
  await LocalDatabase.instance.setSetting('sync', {'enabled': true});
  final sync = SyncService(clientFactory: () => MockClient(handler), now: now);
  addTearDown(sync.dispose);
  sync.setAlarmRinging(false);
  await sync.load(startPolling: false);
  return sync;
}

void main() {
  test(
    'archive caches periods and cursors for five minutes; refresh bypasses it',
    () async {
      var calls = 0, now = _until;
      final sync = await _service((_) async {
        calls++;
        return _response({'records': [], 'more': false});
      }, now: () => now);
      await sync.summary(_from, _until);
      await sync.history(_from, _until);
      await sync.summary(_from, _until);
      await sync.history(_from, _until);
      expect(calls, 2);
      await sync.history(_from, _until, beforeAt: 1, beforeId: 'older');
      expect(calls, 3);
      now = now.add(const Duration(minutes: 5));
      await sync.summary(_from, _until);
      expect(calls, 4);
      sync.invalidateHistoryCache();
      await sync.summary(_from, _until);
      expect(calls, 5);
      // The cache is bounded even when many ranges are visited.
      for (var day = 1; day <= 9; day++) {
        await sync.summary(_from.subtract(Duration(days: day)), _until);
      }
      await sync.summary(_from, _until);
      expect(calls, 15);
    },
  );

  test('new durable data invalidates; repeated native snapshots and downloaded pages do not', () async {
    var calls = 0;
    final sync = await _service((_) async {
      calls++;
      return _response(_summary);
    });
    final db = LocalDatabase.instance;
    await sync.summary(_from, _until);
    await db.saveAlarmState({}, [_event]);
    await sync.summary(_from, _until);
    expect(calls, 2);
    await db.saveAlarmState({}, [_event]);
    await sync.summary(_from, _until);
    expect(calls, 2);
    await db.receive({..._record, 'id': 'older'}, fromHistory: true);
    await sync.summary(_from, _until);
    expect(calls, 2);
    await db.receive({..._record, 'id': 'other-device'});
    await sync.summary(_from, _until);
    expect(calls, 3);
    await db.put('sleep', 'sleep', {'hours': 7}, 1);
    await sync.summary(_from, _until);
    expect(calls, 4);
    await db.remove('sleep', 'sleep');
    await sync.summary(_from, _until);
    expect(calls, 5);
  });

  test('coalesces concurrent requests and retries failures', () async {
    var calls = 0;
    final started = Completer<void>(), reply = Completer<http.Response>();
    final sync = await _service((_) async {
      calls++;
      if (calls == 1) {
        started.complete();
        return reply.future;
      }
      return _response(_summary);
    });
    final first = sync.history(_from, _until);
    await started.future;
    final second = sync.history(_from, _until);
    final check1 = expectLater(first, throwsA(isA<SyncFailure>()));
    final check2 = expectLater(second, throwsA(isA<SyncFailure>()));
    // Let both callers reach the shared request before releasing it.
    await Future<void>.delayed(Duration.zero);
    reply.complete(_response({}, 503));
    await Future.wait([check1, check2]);
    expect(calls, 1);
    await sync.history(_from, _until);
    expect(calls, 2);
  });

  test('local edits during a request prevent caching that response', () async {
    var calls = 0;
    final started = Completer<void>(), reply = Completer<http.Response>();
    final sync = await _service((_) async {
      calls++;
      if (calls == 1) {
        started.complete();
        return reply.future;
      }
      return _response(_summary);
    });
    final first = sync.summary(_from, _until);
    await started.future;
    await LocalDatabase.instance.put('event', 'event', _event, 1);
    reply.complete(_response(_summary));
    await first;
    await sync.summary(_from, _until);
    expect(calls, 2);
  });

  test('uploading pending data invalidates a pre-upload summary; idle sync keeps it', () async {
    var summaries = 0;
    final db = LocalDatabase.instance;
    await db.put('event', 'event', _event, _from.millisecondsSinceEpoch);
    final sync = await _service((request) async {
      return switch (request.url.path) {
        '/v1/summary' => _response({'snoozes': ++summaries}),
        '/v1/account' => _response({'audioAllowed': false, 'sessions': []}),
        '/v1/bootstrap' => _response({'records': [], 'cursor': 0}),
        '/v1/changes' => _response({'records': [], 'cursor': 1, 'more': false}),
        '/v1/sync' => _response({
          'accepted': [
            {'kind': 'event', 'id': 'event', 'revision': 1},
          ],
          'conflicts': [],
        }),
        _ => throw StateError('Unexpected request'),
      };
    });
    await sync.summary(_from, _until);
    await sync.sync();
    expect(sync.error, isNull);
    await sync.summary(_from, _until);
    expect(summaries, 2);
    await sync.sync();
    expect(sync.error, isNull);
    await sync.summary(_from, _until);
    expect(summaries, 2);
  });

  for (final sameAccount in [true, false]) {
    testWidgets('offline summary is scoped to its account ($sameAccount)', (
      tester,
    ) async {
      late SyncService sync;
      final journal = SleepJournal();
      addTearDown(journal.dispose);
      final now = DateTime(2026, 11, 10);
      await tester.runAsync(() async {
        sync = await _service((_) async => _response({}, 503));
        await journal.load();
        await LocalDatabase.instance.setSetting('history_summary', {
          'period':
              '${DateTime(2026, 10, 12).millisecondsSinceEpoch}:${DateTime(2026, 11, 11).millisecondsSinceEpoch}',
          'accountId': sameAccount ? 'account' : 'different-account',
          'endpoint': sync.endpoint,
          'summary': _summary,
        });
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HistoryView(
              events: const [],
              journal: journal,
              now: now,
              archive: true,
              sync: sync,
            ),
          ),
        ),
      );
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
      }
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(
        find.textContaining('Не удалось обновить историю'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Сохранённый расчёт с сервера'),
        sameAccount ? findsOneWidget : findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  test(
    'ringing uses only cached data; opt-out and logout make cache unavailable',
    () async {
      var calls = 0;
      final sync = await _service((_) async {
        calls++;
        return _response(_summary);
      });
      await sync.summary(_from, _until);
      sync.setAlarmRinging(true);
      await sync.summary(_from, _until);
      await expectLater(
        sync.history(_from, _until),
        throwsA(isA<SyncFailure>()),
      );
      expect(calls, 1);
      await sync.setEnabled(false);
      await expectLater(
        sync.summary(_from, _until),
        throwsA(isA<SyncFailure>()),
      );
      await sync.signOut();
      await expectLater(
        sync.summary(_from, _until),
        throwsA(isA<SyncFailure>()),
      );
      expect(calls, 1);
    },
  );

  testWidgets(
    'reopening History reuses cache and the refresh button requests both endpoints',
    (tester) async {
      var summaries = 0, pages = 0;
      late SyncService sync;
      final journal = SleepJournal();
      addTearDown(journal.dispose);
      await tester.runAsync(() async {
        sync = await _service((request) async {
          if (request.url.path == '/v1/summary') {
            summaries++;
            return _response(_summary);
          }
          pages++;
          return _response({
            'records': [_record],
            'more': false,
          });
        });
        await journal.load();
      });
      Future<void> settleArchive() async {
        for (var i = 0; i < 30; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
        }
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(find.textContaining('Не удалось обновить'), findsNothing);
      }

      Future<void> open() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: HistoryView(
                events: const [],
                journal: journal,
                now: DateTime(2026, 11, 10),
                archive: true,
                sync: sync,
              ),
            ),
          ),
        );
        await settleArchive();
      }

      await open();
      expect([summaries, pages], [1, 1]);
      await open();
      expect([summaries, pages], [1, 1]);
      await tester.tap(find.byTooltip('Обновить историю'));
      await settleArchive();
      expect([summaries, pages], [2, 2]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
