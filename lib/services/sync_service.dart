import 'dart:typed_data';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:passkeys/authenticator.dart';
import 'package:passkeys/types.dart';

import 'local_database.dart';
import 'native_extras.dart';

class SyncFailure implements Exception {
  const SyncFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Network operations never participate in native scheduling or dismissal.
class SyncService extends ChangeNotifier {
  SyncService({
    FlutterSecureStorage? secureStorage,
    http.Client Function()? clientFactory,
  }) : _secure = secureStorage ?? const FlutterSecureStorage(),
       _clientFactory = clientFactory ?? http.Client.new;
  static final instance = SyncService();
  final FlutterSecureStorage _secure;
  final http.Client Function() _clientFactory;
  static const defaultEndpoint = String.fromEnvironment('FIVE_MORE_SYNC_URL');
  String endpoint = defaultEndpoint;
  String? accountId, sessionId, _token, pendingRecoveryKey;
  bool enabled = false,
      audioEnabled = false,
      audioAllowed = false,
      busy = false,
      ready = false;
  bool _ringing = true, _foreground = true;
  int _generation = 0;
  Timer? _timer;
  Completer<void>? _foregroundSignal;
  final _activeClients = <http.Client>{};
  void _cancelRequests() {
    for (final client in _activeClients.toList()) {
      client.close();
    }
  }

  DateTime? lastSynced;
  String? error;
  List<Map<String, dynamic>> sessions = [], conflicts = [];
  bool get signedIn => _token != null;

  Future<void> load({bool startPolling = true}) async {
    if (kIsWeb) {
      ready = true;
      return;
    }
    try {
      final saved = await _secure.read(key: 'five_more_sync_session');
      if (saved != null) {
        final data = jsonDecode(saved) as Map<String, dynamic>;
        endpoint = data['endpoint'] as String;
        _token = data['token'] as String;
        accountId = data['accountId'] as String;
        sessionId = data['sessionId'] as String;
        pendingRecoveryKey = data['recoveryKey'] as String?;
      }
      final settings = await LocalDatabase.instance.setting('sync') ?? {};
      enabled = settings['enabled'] == true;
      audioEnabled = settings['audioEnabled'] == true;
      lastSynced = settings['lastSynced'] is int
          ? DateTime.fromMillisecondsSinceEpoch(settings['lastSynced'] as int)
          : null;
    } catch (_) {
      error =
          'Не удалось открыть синхронизацию. Локальные будильники доступны.';
    }
    ready = true;
    if (startPolling) {
      _timer = Timer.periodic(
        const Duration(minutes: 1),
        (_) => unawaited(sync()),
      );
      unawaited(sync());
    }
    notifyListeners();
  }

  void setAlarmRinging(bool ringing) {
    if (_ringing == ringing) return;
    _ringing = ringing;
    if (ringing) {
      _generation++;
      _cancelRequests();
    } else {
      unawaited(sync());
    }
  }

  void setForeground(bool value) {
    _foreground = value;
    if (value) {
      _foregroundSignal?.complete();
      _foregroundSignal = null;
    } else {
      _foregroundSignal ??= Completer<void>();
    }
    if (!value) {
      _generation++;
      _cancelRequests();
    } else {
      unawaited(sync());
    }
  }

  Future<void> _afterCredentialPrompt() async {
    if (!_foreground) {
      await _foregroundSignal?.future.timeout(const Duration(seconds: 30));
    }
    if (_ringing) {
      throw const SyncFailure('Закончи звонок, затем повтори вход.');
    }
  }

  void configureEndpoint(String value) {
    if (signedIn) throw const SyncFailure('Сначала выйди из аккаунта.');
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const SyncFailure('Укажи HTTPS-адрес сервера без пути.');
    }
    endpoint = uri.origin;
  }

  Future<http.Response> _request(
    String method,
    String path, {
    Object? data,
    Uint8List? bytes,
    bool authenticated = true,
  }) async {
    if (_ringing || !_foreground) {
      throw const SyncFailure('Синхронизация продолжится после звонка.');
    }
    if (!endpoint.startsWith('https://')) {
      throw const SyncFailure('Сначала укажи HTTPS-адрес сервера.');
    }
    final client = _clientFactory();
    _activeClients.add(client);
    final generation = _generation;
    try {
      final request = http.Request(method, Uri.parse('$endpoint$path'))
        ..followRedirects = false;
      if (authenticated) {
        if (_token == null) throw const SyncFailure('Войди в аккаунт.');
        request.headers['Authorization'] = 'Bearer $_token';
      }
      if (bytes != null) {
        request.headers['Content-Type'] = 'audio/mp4';
        request.bodyBytes = bytes;
      } else if (data != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(data);
      }
      final stream = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      Future<Uint8List> boundedBody() async {
        final builder = BytesBuilder(copy: false);
        final limit = path.startsWith('/v1/audio/') ? 20000000 : 24000000;
        await for (final chunk in stream.stream) {
          if (builder.length + chunk.length > limit) {
            throw const SyncFailure('Ответ сервера слишком большой.');
          }
          if (generation != _generation) {
            throw const SyncFailure('Синхронизация приостановлена.');
          }
          builder.add(chunk);
        }
        return builder.takeBytes();
      }

      final response = http.Response.bytes(
        await boundedBody().timeout(const Duration(seconds: 45)),
        stream.statusCode,
        headers: stream.headers,
      );
      if (generation != _generation || _ringing) {
        throw const SyncFailure('Синхронизация приостановлена.');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (response.statusCode == 401) {
          throw const SyncFailure('Сессия закончилась. Войди снова.');
        }
        if (response.statusCode == 403 &&
            response.body.contains('fresh_sign_in_required')) {
          throw const SyncFailure(
            'Для удаления аккаунта выйди и войди с passkey заново, затем повтори удаление в течение 5 минут.',
          );
        }
        if (response.statusCode == 403) {
          throw const SyncFailure('Сервер не разрешил это действие.');
        }
        if (response.statusCode == 413) {
          throw const SyncFailure(
            'Лимит хранилища или размера записи достигнут.',
          );
        }
        if (response.statusCode == 429) {
          throw const SyncFailure(
            'Слишком много запросов. Попробуй через минуту.',
          );
        }
        throw const SyncFailure(
          'Сервер не принял данные. Локальная копия сохранена.',
        );
      }
      return response;
    } finally {
      client.close();
      _activeClients.remove(client);
    }
  }

  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Object? data,
    bool authenticated = true,
  }) async => jsonDecode(
    (await _request(
      method,
      path,
      data: data,
      authenticated: authenticated,
    )).body,
  ) as Map<String, dynamic>;

  Future<void> _acceptSession(Map<String, dynamic> value) async {
    final bound = await LocalDatabase.instance.setting('sync_binding');
    if (bound != null &&
        (bound['accountId'] != value['accountId'] ||
            bound['endpoint'] != endpoint)) {
      throw const SyncFailure(
        'Локальная история связана с другим аккаунтом. Войди в прежний аккаунт.',
      );
    }
    await _secure.write(
      key: 'five_more_sync_session',
      value: jsonEncode({
        'endpoint': endpoint,
        'token': value['token'],
        'accountId': value['accountId'],
        'sessionId': value['sessionId'],
        'recoveryKey': value['recoveryKey'],
      }),
    );
    accountId = value['accountId'] as String;
    sessionId = value['sessionId'] as String;
    _token = value['token'] as String;
    audioAllowed = value['audioAllowed'] == true;
    pendingRecoveryKey = value['recoveryKey'] as String?;
    await LocalDatabase.instance.setSetting('sync_binding', {
      'accountId': accountId,
      'endpoint': endpoint,
    });
    enabled = true;
    await _saveSettings();
    notifyListeners();
  }

  Future<String?> register({bool addPasskey = false}) async {
    if (!addPasskey &&
        await LocalDatabase.instance.setting('sync_binding') != null) {
      throw const SyncFailure(
        'История уже связана с аккаунтом. Войди с passkey или восстанови доступ.',
      );
    }
    final options = await _json(
      'POST',
      '/v1/auth/register/options',
      authenticated: addPasskey,
    );
    final response = await PasskeyAuthenticator().register(
      RegisterRequestType.fromJson(
        Map<String, dynamic>.from(options['options'] as Map),
      ),
    );
    await _afterCredentialPrompt();
    final result = await _json(
      'POST',
      '/v1/auth/register/verify',
      authenticated: addPasskey,
      data: {
        'challengeId': options['challengeId'],
        'credential': response.toJson(),
        'deviceName': defaultTargetPlatform.name,
      },
    );
    if (!addPasskey) await _acceptSession(result);
    return result['recoveryKey'] as String?;
  }

  Future<String?> _boundAccount() async {
    final binding = await LocalDatabase.instance.setting('sync_binding');
    if (binding != null && binding['endpoint'] != endpoint) {
      throw const SyncFailure(
        'История связана с другим сервером. Верни прежний адрес.',
      );
    }
    return binding?['accountId'] as String?;
  }

  Future<void> login() async {
    final expectedAccount = await _boundAccount();
    final options = await _json(
      'POST',
      '/v1/auth/login/options',
      authenticated: false,
    );
    final response = await PasskeyAuthenticator().authenticate(
      AuthenticateRequestType.fromJson(
        Map<String, dynamic>.from(options['options'] as Map),
      ),
    );
    await _afterCredentialPrompt();
    await _acceptSession(
      await _json(
        'POST',
        '/v1/auth/login/verify',
        authenticated: false,
        data: {
          'challengeId': options['challengeId'],
          'credential': response.toJson(),
          'expectedAccountId': expectedAccount,
          'deviceName': defaultTargetPlatform.name,
        },
      ),
    );
  }

  Future<String> recover(String recoveryKey) async {
    final expectedAccount = await _boundAccount();
    final result = await _json(
      'POST',
      '/v1/auth/recover',
      authenticated: false,
      data: {
        'recoveryKey': recoveryKey.trim(),
        'expectedAccountId': expectedAccount,
        'deviceName': defaultTargetPlatform.name,
      },
    );
    await _acceptSession(result);
    return result['recoveryKey'] as String;
  }

  Future<void> acknowledgeRecoveryKey() async {
    if (!signedIn) return;
    await _secure.write(
      key: 'five_more_sync_session',
      value: jsonEncode({
        'endpoint': endpoint,
        'token': _token,
        'accountId': accountId,
        'sessionId': sessionId,
      }),
    );
    pendingRecoveryKey = null;
    notifyListeners();
  }

  Future<void> refreshAccount() async {
    final value = await _json('GET', '/v1/account');
    audioAllowed = value['audioAllowed'] == true;
    sessions = (value['sessions'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    if (!audioAllowed) audioEnabled = false;
    notifyListeners();
  }

  Future<void> revokeSession(String id) async {
    await _json('DELETE', '/v1/sessions/$id');
    if (id == sessionId) {
      await signOut();
    } else {
      await refreshAccount();
    }
  }

  Future<void> signOut() async {
    _generation++;
    _cancelRequests();
    enabled = false;
    audioEnabled = false;
    if (signedIn) {
      try {
        await _json('DELETE', '/v1/sessions/$sessionId');
      } catch (_) {
        /* Local logout also works offline. */
      }
    }
    await _secure.delete(key: 'five_more_sync_session');
    _token = null;
    pendingRecoveryKey = null;
    accountId = null;
    sessionId = null;
    sessions = [];
    await _saveSettings();
    notifyListeners();
  }

  Future<void> deleteAccount() async {
    _generation++;
    _cancelRequests();
    final wasEnabled = enabled;
    enabled = false;
    try {
      await _json('DELETE', '/v1/account');
    } catch (_) {
      enabled = wasEnabled;
      rethrow;
    }
    await signOut();
    final db = await LocalDatabase.instance.database;
    await db.transaction((txn) async {
      await txn.delete(
        'settings',
        where: 'key IN (?, ?, ?, ?)',
        whereArgs: [
          'sync_binding',
          'sync_cursor',
          'uploaded_audio',
          'history_summary',
        ],
      );
      await txn.update('records', {'revision': 0, 'dirty': 1});
    });
    lastSynced = null;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    enabled = value;
    if (!value) {
      _generation++;
      _cancelRequests();
    }
    await _saveSettings();
    notifyListeners();
    if (value) unawaited(sync());
  }

  Future<void> setAudioEnabled(bool value) async {
    if (value && !audioAllowed) {
      throw const SyncFailure('Загрузка аудио недоступна для этого аккаунта.');
    }
    audioEnabled = value;
    if (!value) {
      _generation++;
      _cancelRequests();
    }
    await _saveSettings();
    notifyListeners();
    if (value) unawaited(sync());
  }

  Future<void> _saveSettings() => LocalDatabase.instance.setSetting('sync', {
    'enabled': enabled,
    'audioEnabled': audioEnabled,
    'lastSynced': lastSynced?.millisecondsSinceEpoch,
  });

  Future<void> sync() async {
    if (!ready ||
        kIsWeb ||
        !enabled ||
        !signedIn ||
        busy ||
        _ringing ||
        !_foreground) {
      return;
    }
    busy = true;
    error = null;
    notifyListeners();
    final generation = _generation;
    final db = LocalDatabase.instance;
    bool active() =>
        generation == _generation && enabled && !_ringing && _foreground;
    try {
      await refreshAccount();
      var cursorData = await db.setting('sync_cursor');
      if (cursorData == null) {
        final bootstrap = await _json('GET', '/v1/bootstrap');
        if (!active()) return;
        for (final raw in bootstrap['records'] as List) {
          await db.receive(Map<String, dynamic>.from(raw as Map));
        }
        cursorData = {'cursor': bootstrap['cursor']};
        await db.setSetting('sync_cursor', cursorData);
      }
      conflicts = [];
      while (active()) {
        final pending = await db.pending(audio: audioAllowed && audioEnabled);
        if (pending.isEmpty) break;
        final result = await _json(
          'POST',
          '/v1/sync',
          data: {
            'records': pending
                .map(
                  (row) => {
                    'kind': row['kind'],
                    'id': row['id'],
                    'data': jsonDecode(row['data'] as String),
                    'revision': row['revision'],
                    'deleted': row['deleted'] == 1,
                  },
                )
                .toList(),
          },
        );
        if (!active()) return;
        for (final ack in result['accepted'] as List) {
          final sent = pending.firstWhere(
            (row) => row['kind'] == ack['kind'] && row['id'] == ack['id'],
          );
          await db.acknowledge(sent, ack['revision'] as int);
        }
        conflicts.addAll(
          (result['conflicts'] as List).map(
            (e) => Map<String, dynamic>.from(e as Map),
          ),
        );
        if (conflicts.isNotEmpty) {
          error =
              'Есть изменения с другого устройства. Выбери, какие сохранить.';
          break;
        }
      }
      var cursor = cursorData['cursor'] as int;
      while (active()) {
        final page = await _json('GET', '/v1/changes?cursor=$cursor');
        if (!active()) return;
        for (final raw in page['records'] as List) {
          await db.receive(Map<String, dynamic>.from(raw as Map));
        }
        cursor = page['cursor'] as int;
        await db.setSetting('sync_cursor', {'cursor': cursor});
        if (page['more'] != true) break;
      }
      if (audioAllowed && audioEnabled && active()) {
        final uploaded = await db.setting('uploaded_audio') ?? {};
        for (final note in await db.records('note')) {
          if (!active() || !audioEnabled) return;
          final id = note['file'] as String;
          if (uploaded[id] == true) continue;
          // Downloaded notes are already present on the server. Try local data
          // only for this device's files; no recording is opened while ringing.
          Uint8List? bytes;
          try {
            bytes = await NativeExtras.call<Uint8List>('readNote', {
              'file': id,
            });
          } catch (_) {
            continue;
          }
          if (bytes == null) continue;
          await _request('PUT', '/v1/audio/$id', bytes: bytes);
          if (!active()) return;
          uploaded[id] = true;
          await db.setSetting('uploaded_audio', uploaded);
        }
      }
      if (active() && conflicts.isEmpty) {
        lastSynced = DateTime.now();
        await _saveSettings();
      }
    } catch (e) {
      if (active()) error = e is SyncFailure ? e.message : 'Сервер недоступен. Данные сохранены на телефоне; повторим позже.';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> resolveConflicts({required bool keepLocal}) async {
    final db = LocalDatabase.instance;
    for (final record in conflicts) {
      final database = await db.database;
      await database.update(
        'records',
        {
          'revision': record['revision'],
          if (!keepLocal || record['kind'] == 'event') 'dirty': 0,
        },
        where: 'kind = ? AND id = ?',
        whereArgs: [record['kind'], record['id']],
      );
      if (!keepLocal || record['kind'] == 'event') await db.receive(record);
    }
    conflicts = [];
    error = null;
    await sync();
  }

  Future<Map<String, dynamic>> summary(DateTime from, DateTime until) async {
    String? zone;
    try {
      zone = await NativeExtras.call<String>('timeZone');
    } catch (_) {}
    return _json(
      'GET',
      '/v1/summary?start=${from.millisecondsSinceEpoch}&end=${until.millisecondsSinceEpoch}&offset_minutes=${until.timeZoneOffset.inMinutes}${zone == null ? '' : '&time_zone=${Uri.encodeQueryComponent(zone)}'}',
    );
  }

  Future<Map<String, dynamic>> history(
    DateTime from,
    DateTime until, {
    int? beforeAt,
    String? beforeId,
  }) => _json(
    'GET',
    '/v1/history?start=${from.millisecondsSinceEpoch}&end=${until.millisecondsSinceEpoch}${beforeAt == null ? '' : '&before_at=$beforeAt&before_id=${Uri.encodeQueryComponent(beforeId!)}'}',
  );
  Future<void> downloadNote(String id) async {
    if (!enabled || !audioEnabled || !audioAllowed) {
      throw const SyncFailure('Включи синхронизацию аудио.');
    }
    final response = await _request('GET', '/v1/audio/$id');
    await NativeExtras.call<void>('writeNote', {
      'file': id,
      'bytes': response.bodyBytes,
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _cancelRequests();
    super.dispose();
  }
}
