import 'dart:async';
import 'dart:convert';

import 'package:five_more/services/local_database.dart';
import 'package:five_more/services/sync_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  Future<SyncService> service(
    Future<http.Response> Function(http.Request) handle, {
    bool enabled = true,
    bool audio = false,
  }) async {
    FlutterSecureStorage.setMockInitialValues({
      'five_more_sync_session': jsonEncode({
        'endpoint': 'https://sync.example.test',
        'token': 'test-session',
        'accountId': 'test-account',
        'sessionId': 'session',
      }),
    });
    await LocalDatabase.instance.setSetting('sync', {
      'enabled': enabled,
      'audioEnabled': audio,
    });
    final sync = SyncService(clientFactory: () => MockClient(handle));
    addTearDown(sync.dispose);
    sync.setAlarmRinging(false);
    await sync.load(startPolling: false);
    return sync;
  }

  http.Response response(Object value, [int code = 200]) => http.Response(
    jsonEncode(value),
    code,
    headers: {'content-type': 'application/json'},
  );
  final event = {
    'eventId': 'event',
    'id': 'alarm',
    'occurrenceId': 'wake',
    'type': 'fired',
    'at': 1793200000000,
  };

  test(
    'disabled sync sends nothing and ordinary accounts cannot opt into audio',
    () async {
      var requests = 0;
      final sync = await service((_) async {
        requests++;
        return response({});
      }, enabled: false);
      await sync.sync();
      await expectLater(
        sync.setAudioEnabled(true),
        throwsA(isA<SyncFailure>()),
      );
      expect(requests, 0);
    },
  );

  test('successful sync acknowledges metadata and never reads ordinary-account audio', () async {
    final db = LocalDatabase.instance;
    await db.put('event', 'event', event, 1793200000000);
    await db.put('note', 'local.m4a', {
      'file': 'local.m4a',
      'at': 1,
      'seconds': 300,
    }, 1);
    final calls = <String>[];
    final sync = await service((request) async {
      calls.add(request.url.path);
      expect(request.headers['Authorization'], 'Bearer test-session');
      switch (request.url.path) {
        case '/v1/account':
          return response({'audioAllowed': false, 'sessions': []});
        case '/v1/bootstrap':
          return response({'records': [], 'cursor': 0});
        case '/v1/sync':
          final rows = jsonDecode(request.body)['records'] as List;
          expect(rows.map((r) => r['kind']), ['event']);
          return response({
            'accepted': [
              {'kind': 'event', 'id': 'event', 'revision': 1},
            ],
            'conflicts': [],
          });
        case '/v1/changes':
          return response({'records': [], 'cursor': 1, 'more': false});
        default:
          fail('Unexpected endpoint: ${request.url.path}');
      }
    }, audio: true);
    await sync.sync();
    expect(sync.error, isNull);
    expect(sync.audioEnabled, isFalse);
    expect(await db.pending(), isEmpty);
    expect((await db.pending(audio: true)).single['kind'], 'note');
    expect(calls.any((p) => p.contains('audio')), isFalse);
  });

  test(
    'lost response leaves pending data retryable without advancing the cursor',
    () async {
      final db = LocalDatabase.instance;
      await db.put('event', 'event', event, 1793200000000);
      await db.setSetting('sync_cursor', {'cursor': 12});
      final sync = await service((request) async {
        if (request.url.path == '/v1/account') {
          return response({'audioAllowed': false, 'sessions': []});
        }
        throw http.ClientException('offline');
      });
      await sync.sync();
      expect(sync.error, isNotNull);
      expect(await db.pending(), hasLength(1));
      expect((await db.setting('sync_cursor'))!['cursor'], 12);
    },
  );

  test(
    'ringing cancels a response before it can persist or start another request',
    () async {
      final received = Completer<void>(), release = Completer<http.Response>();
      var requests = 0;
      final sync = await service((request) async {
        requests++;
        received.complete();
        return release.future;
      });
      final pending = sync.sync();
      await received.future;
      sync.setAlarmRinging(true);
      release.complete(response({'audioAllowed': true, 'sessions': []}));
      await pending;
      expect(requests, 1);
      expect(sync.audioAllowed, isFalse);
      expect(sync.lastSynced, isNull);
      await sync.sync();
      expect(requests, 1);
    },
  );

  test(
    'a recovery key is never sent to a server different from the bound history',
    () async {
      await LocalDatabase.instance.setSetting('sync_binding', {
        'accountId': 'account',
        'endpoint': 'https://original.example.test',
      });
      var requests = 0;
      final sync = SyncService(
        clientFactory: () => MockClient((_) async {
          requests++;
          return response({});
        }),
      );
      addTearDown(sync.dispose);
      sync.setAlarmRinging(false);
      sync.configureEndpoint('https://different.example.test');
      await expectLater(
        sync.recover('synthetic-recovery-key'),
        throwsA(isA<SyncFailure>()),
      );
      expect(requests, 0);
    },
  );

  test('server redirects are not followed with the bearer token', () async {
    final sync = await service((request) async {
      expect(request.followRedirects, isFalse);
      return http.Response(
        '',
        307,
        headers: {'location': 'https://elsewhere.example.test'},
      );
    });
    await sync.sync();
    expect(sync.error, isNotNull);
    expect(sync.lastSynced, isNull);
  });
}
