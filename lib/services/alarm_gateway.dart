import 'package:flutter/services.dart';

import '../models/alarm.dart';

class AlarmDeviceStatus {
  const AlarmDeviceStatus({
    this.platform = 'preview',
    this.supported = false,
    this.exactAlarms = false,
    this.notifications = false,
    this.fullScreenIntent = false,
    this.challengeEnforced = true,
    this.scheduledCount = 0,
    this.error,
    this.alarms = const [],
  });

  final String platform;
  final bool supported;
  final bool exactAlarms;
  final bool notifications;
  final bool fullScreenIntent;
  final bool challengeEnforced;
  final int scheduledCount;
  final String? error;
  final List<Alarm> alarms;
  bool get canSchedule => supported && exactAlarms && notifications;
  bool get needsAttention =>
      supported && (!exactAlarms || !notifications || !fullScreenIntent);

  factory AlarmDeviceStatus.fromJson(Map<String, dynamic> json) =>
      AlarmDeviceStatus(
        platform: json['platform'] as String? ?? 'preview',
        supported: json['supported'] == true,
        exactAlarms: json['exactAlarms'] == true,
        notifications: json['notifications'] == true,
        fullScreenIntent: json['fullScreenIntent'] == true,
        challengeEnforced: json['challengeEnforced'] != false,
        scheduledCount: intValue(json['scheduledCount'], 0),
        error: alarmErrorMessage(json['error'] as String?),
        alarms: (json['alarms'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => Alarm.fromJson(Map<String, dynamic>.from(item)))
            .where((alarm) => !alarm.id.startsWith('preview:'))
            .toList(),
      );
}

String? alarmErrorMessage(String? error) => switch (error) {
  'exact_alarm_permission' =>
    'Разреши точное срабатывание в настройках телефона.',
  'alarm_active' => 'Сначала заверши текущий подъём, затем меняй расписание.',
  'snooze_limit' => 'Переносы закончились. Пора пройти задание.',
  'not_found' => 'Будильник не найден. Обнови список и попробуй ещё раз.',
  'not_ringing' => 'Этот будильник уже не звонит.',
  'invalid_id' ||
  'invalid_hour' ||
  'invalid_minute' ||
  'invalid_schedule' => 'Проверь время, дни недели и настройки переноса.',
  'schedule_failed' =>
    'Не удалось поставить будильник. Проверь системные разрешения.',
  _ => error,
};

class AlarmResult {
  const AlarmResult({
    required this.ok,
    this.error,
    this.nextAt,
    this.alarm,
    this.snoozesUsed,
  });
  final bool ok;
  final String? error;
  final DateTime? nextAt;
  final Alarm? alarm;
  final int? snoozesUsed;

  factory AlarmResult.fromJson(Map<String, dynamic> json) => AlarmResult(
    ok: json['ok'] == true,
    error: alarmErrorMessage(json['error'] as String?),
    nextAt: parseNextTimestamp(json['nextAt']),
    alarm: json['alarm'] is Map
        ? Alarm.fromJson(Map<String, dynamic>.from(json['alarm'] as Map))
        : null,
    snoozesUsed: json['snoozesUsed'] is num
        ? (json['snoozesUsed'] as num).toInt()
        : null,
  );
}

abstract class AlarmGateway {
  Future<AlarmDeviceStatus> status();
  Future<void> requestPermissions();
  Future<AlarmResult> schedule(Alarm alarm);
  Future<AlarmResult> cancel(String id);
  Future<AlarmResult> snooze(String id);
  Future<AlarmResult> dismiss(String id, {bool emergency = false});
  Future<AlarmResult> testAlarm(String id);
  Future<RingingAlarm?> getRingingAlarm();
  Future<List<AlarmEvent>> drainEvents();
  Future<void> ackEvents(List<String> eventIds);
}

class NativeAlarmGateway implements AlarmGateway {
  static const _channel = MethodChannel('five_more/alarm');

  Future<Map<String, dynamic>> _map(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    final result = await _channel.invokeMethod<Object?>(method, args);
    if (result is! Map) {
      throw const FormatException('Invalid native alarm response');
    }
    return Map<String, dynamic>.from(result);
  }

  @override
  Future<AlarmDeviceStatus> status() async {
    try {
      return AlarmDeviceStatus.fromJson(await _map('status'));
    } on MissingPluginException {
      return const AlarmDeviceStatus();
    } on PlatformException catch (error) {
      return AlarmDeviceStatus(error: error.message ?? error.code);
    }
  }

  @override
  Future<void> requestPermissions() async {
    await _channel.invokeMethod<Object?>('requestPermissions');
  }

  Future<AlarmResult> _action(String method, Map<String, Object?> args) async {
    try {
      return AlarmResult.fromJson(await _map(method, args));
    } on MissingPluginException {
      return const AlarmResult(
        ok: false,
        error: 'На этой платформе доступна только тренировка.',
      );
    } on PlatformException catch (error) {
      return AlarmResult(ok: false, error: error.message ?? error.code);
    }
  }

  @override
  Future<AlarmResult> schedule(Alarm alarm) =>
      _action('schedule', alarm.toJson()..remove('nextAt'));
  @override
  Future<AlarmResult> cancel(String id) => _action('cancel', {'id': id});
  @override
  Future<AlarmResult> snooze(String id) => _action('snooze', {'id': id});
  @override
  Future<AlarmResult> dismiss(String id, {bool emergency = false}) =>
      _action('dismiss', {'id': id, 'emergency': emergency});
  @override
  Future<AlarmResult> testAlarm(String id) => _action('testAlarm', {'id': id});

  @override
  Future<RingingAlarm?> getRingingAlarm() async {
    final result = await _channel.invokeMethod<Object?>('getRingingAlarm');
    if (result is! Map) return null;
    final map = Map<String, dynamic>.from(result);
    if (map['state'] == 'snoozed' || map['state'] == 'dismissed') return null;
    return RingingAlarm.fromJson(map);
  }

  @override
  Future<List<AlarmEvent>> drainEvents() async {
    final result = await _channel.invokeMethod<Object?>('drainEvents');
    if (result is! List) return [];
    return result
        .whereType<Map>()
        .map((event) => AlarmEvent.fromJson(Map<String, dynamic>.from(event)))
        .toList();
  }

  @override
  Future<void> ackEvents(List<String> eventIds) async {
    await _channel.invokeMethod<Object?>('ackEvents', {'eventIds': eventIds});
  }
}
