import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

/// App history lives here. Native alarm state stays in its Direct Boot store.
class LocalDatabase {
  LocalDatabase({this.path});
  static LocalDatabase instance = LocalDatabase();
  final String? path;
  Future<Database>? _opening;
  Future<Database> get database => _opening ??= _open();

  Future<Database> _open() async {
    final db = await openDatabase(
      path ?? '${await getDatabasesPath()}/five_more.db',
      version: 1,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE records (kind TEXT NOT NULL, id TEXT NOT NULL, data TEXT NOT NULL, at INTEGER NOT NULL, revision INTEGER NOT NULL DEFAULT 0, dirty INTEGER NOT NULL DEFAULT 1, deleted INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(kind,id))',
        );
        await db.execute(
          'CREATE INDEX records_time ON records(kind,at DESC,id)',
        );
        await db.execute('CREATE INDEX records_pending ON records(dirty,kind)');
      },
    );
    try {
      final migrated = await db.query(
        'settings',
        where: 'key = ?',
        whereArgs: ['legacy_migrated'],
      );
      if (migrated.isEmpty) {
        final prefs = await SharedPreferences.getInstance();
        // Parse everything before beginning. Corrupt legacy data must not be
        // replaced with an empty database or acknowledged as migrated.
        final alarmRaw = prefs.getString('five_more.state.v1');
        final sleepRaw = prefs.getString('five_more.sleep.v1');
        final alarms = alarmRaw == null
            ? <String, dynamic>{}
            : jsonDecode(alarmRaw) as Map<String, dynamic>;
        final sleep = sleepRaw == null
            ? <String, dynamic>{}
            : jsonDecode(sleepRaw) as Map<String, dynamic>;
        await db.transaction((txn) async {
          await txn.insert('settings', {
            'key': 'alarm_state',
            'value': jsonEncode({...alarms, 'events': []}),
          });
          await txn.insert('settings', {
            'key': 'journal',
            'value': jsonEncode({...sleep, 'entries': [], 'notes': []}),
          });
          for (final raw in (alarms['events'] as List? ?? [])) {
            final row = Map<String, dynamic>.from(raw as Map);
            if ((row['id'] as String? ?? '').startsWith('preview:')) continue;
            await _put(
              txn,
              'event',
              row['eventId'] as String,
              row,
              row['at'] as int,
            );
          }
          for (final raw in (sleep['entries'] as List? ?? [])) {
            final row = Map<String, dynamic>.from(raw as Map);
            await _put(
              txn,
              'sleep',
              row['occurrenceId'] as String,
              row,
              row['wokeAt'] as int,
            );
          }
          for (final raw in (sleep['notes'] as List? ?? [])) {
            final row = Map<String, dynamic>.from(raw as Map);
            await _put(
              txn,
              'note',
              row['file'] as String,
              row,
              row['at'] as int,
            );
          }
          await txn.insert('settings', {
            'key': 'legacy_migrated',
            'value': 'true',
          });
        });
        // Keep the old snapshot for rollback; it is no longer the live store.
      }
      return db;
    } catch (_) {
      await db.close();
      _opening = null;
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> setting(String key) async {
    final rows = await (await database).query(
      'settings',
      where: 'key = ?',
      whereArgs: [key],
    );
    return rows.isEmpty
        ? null
        : jsonDecode(rows.first['value'] as String) as Map<String, dynamic>;
  }

  Future<void> setSetting(String key, Map<String, Object?> value) async =>
      (await database)
          .insert('settings', {
            'key': key,
            'value': jsonEncode(value),
          }, conflictAlgorithm: ConflictAlgorithm.replace)
          .then((_) {});

  static Future<void> _put(
    DatabaseExecutor db,
    String kind,
    String id,
    Map<String, dynamic> value,
    int at,
  ) async {
    final data = jsonEncode(value);
    final old = await db.query(
      'records',
      where: 'kind = ? AND id = ?',
      whereArgs: [kind, id],
    );
    if (kind == 'event' && old.isNotEmpty) return;
    if (old.isNotEmpty &&
        old.first['data'] == data &&
        old.first['deleted'] == 0) {
      return;
    }
    if (old.isEmpty) {
      await db.insert('records', {
        'kind': kind,
        'id': id,
        'data': data,
        'at': at,
      });
    } else {
      await db.update(
        'records',
        {'data': data, 'at': at, 'dirty': 1, 'deleted': 0},
        where: 'kind = ? AND id = ?',
        whereArgs: [kind, id],
      );
    }
  }

  Future<void> put(
    String kind,
    String id,
    Map<String, dynamic> value,
    int at,
  ) async =>
      (await database).transaction((txn) => _put(txn, kind, id, value, at));

  Future<void> saveAlarmState(
    Map<String, Object?> state,
    Iterable<Map<String, Object?>> events,
  ) async {
    await (await database).transaction((txn) async {
      await txn.insert('settings', {
        'key': 'alarm_state',
        'value': jsonEncode(state),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      for (final event in events) {
        if ((event['id'] as String).startsWith('preview:')) continue;
        await _put(
          txn,
          'event',
          event['eventId'] as String,
          event,
          event['at'] as int,
        );
      }
    });
  }

  Future<List<Map<String, dynamic>>> records(
    String kind, {
    int? limit,
    int offset = 0,
    DateTime? from,
    DateTime? until,
  }) async {
    final rows = await (await database).query(
      'records',
      where:
          'kind = ? AND deleted = 0${from == null ? '' : ' AND at >= ?'}${until == null ? '' : ' AND at < ?'}',
      whereArgs: [
        kind,
        ?from?.millisecondsSinceEpoch,
        ?until?.millisecondsSinceEpoch,
      ],
      orderBy: 'at DESC, id DESC',
      limit: limit,
      offset: offset,
    );
    return rows
        .map((row) => jsonDecode(row['data'] as String) as Map<String, dynamic>)
        .toList();
  }

  Future<bool> isDeleted(String kind, String id) async =>
      (await (await database).query(
        'records',
        columns: ['id'],
        where: 'kind = ? AND id = ? AND deleted = 1',
        whereArgs: [kind, id],
      )).isNotEmpty;
  Future<void> remove(String kind, String id) async {
    await (await database).update(
      'records',
      {'deleted': 1, 'dirty': 1},
      where: 'kind = ? AND id = ?',
      whereArgs: [kind, id],
    );
  }

  Future<List<Map<String, Object?>>> pending({
    bool audio = false,
  }) async => (await database).query(
    'records',
    where:
        'dirty = 1 AND (kind ${audio ? "IN ('event','sleep','note')" : "IN ('event','sleep')"} OR (kind = ? AND deleted = 1 AND revision > 0))',
    whereArgs: ['note'],
    orderBy: 'at,id',
    limit: 100,
  );

  /// Only acknowledge the exact payload sent. An edit during the HTTP request
  /// stays pending, but advances its base revision to the server's reply.
  Future<void> acknowledge(Map<String, Object?> sent, int revision) async {
    await (await database).rawUpdate(
      'UPDATE records SET revision = ?, dirty = CASE WHEN data = ? AND deleted = ? THEN 0 ELSE 1 END WHERE kind = ? AND id = ?',
      [revision, sent['data'], sent['deleted'], sent['kind'], sent['id']],
    );
  }

  Future<bool> receive(Map<String, dynamic> record) async {
    return (await database).transaction((txn) async {
      final old = await txn.query(
        'records',
        where: 'kind = ? AND id = ?',
        whereArgs: [record['kind'], record['id']],
      );
      if (old.isNotEmpty && old.first['dirty'] == 1) return false;
      if (old.isNotEmpty &&
          (old.first['revision'] as int) > (record['revision'] as int)) {
        return true;
      }
      await txn.insert('records', {
        'kind': record['kind'],
        'id': record['id'],
        'data': jsonEncode(record['data']),
        'at': record['at'],
        'revision': record['revision'],
        'dirty': 0,
        'deleted': record['deleted'] == true ? 1 : 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return true;
    });
  }

  Future<void> close() async {
    final future = _opening;
    _opening = null;
    if (future != null) await (await future).close();
  }
}

bool get usesSqlite => !kIsWeb;
