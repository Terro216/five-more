import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/alarm.dart';
import 'local_database.dart';
import '../models/device_alarm_check.dart';

class AlarmSnapshot {
  const AlarmSnapshot({
    this.alarms = const [],
    this.events = const [],
    this.deviceCheck,
  });
  final List<Alarm> alarms;
  final List<AlarmEvent> events;
  final DeviceAlarmCheck? deviceCheck;
}

abstract class AlarmStorage {
  Future<AlarmSnapshot> load();
  Future<void> save(AlarmSnapshot snapshot);
}

class LocalAlarmStorage implements AlarmStorage {
  static const _key = 'five_more.state.v1';

  @override
  Future<AlarmSnapshot> load() async {
    if (usesSqlite) {
      final db = LocalDatabase.instance;
      final state = await db.setting('alarm_state') ?? {};
      return AlarmSnapshot(
        alarms: (state['alarms'] as List? ?? [])
            .map((e) => Alarm.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        events: (await db.records(
          'event',
          limit: 500,
        )).reversed.map(AlarmEvent.fromJson).toList(),
        deviceCheck: DeviceAlarmCheck.tryFromJson(state['deviceCheck']),
      );
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const AlarmSnapshot();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return AlarmSnapshot(
      deviceCheck: DeviceAlarmCheck.tryFromJson(json['deviceCheck']),
      alarms: (json['alarms'] as List? ?? [])
          .whereType<Map>()
          .map((item) => Alarm.fromJson(Map<String, dynamic>.from(item)))
          .toList(),
      events: (json['events'] as List? ?? [])
          .whereType<Map>()
          .map((item) => AlarmEvent.fromJson(Map<String, dynamic>.from(item)))
          .toList(),
    );
  }

  @override
  Future<void> save(AlarmSnapshot snapshot) async {
    if (usesSqlite) {
      await LocalDatabase.instance.saveAlarmState({
        'alarms': snapshot.alarms.map((a) => a.toJson()).toList(),
        'deviceCheck': snapshot.deviceCheck?.toJson(),
      }, snapshot.events.map((e) => e.toJson()));
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(
      _key,
      jsonEncode({
        'version': 2,
        'alarms': snapshot.alarms.map((alarm) => alarm.toJson()).toList(),
        'events': snapshot.events.map((event) => event.toJson()).toList(),
        'deviceCheck': snapshot.deviceCheck?.toJson(),
      }),
    );
    if (!saved) {
      throw StateError('Не удалось сохранить настройки на устройстве.');
    }
  }
}
