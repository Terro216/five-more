import 'package:five_more/models/alarm.dart';
import 'package:five_more/services/alarm_gateway.dart';
import 'package:five_more/services/alarm_storage.dart';

class MemoryAlarmStorage implements AlarmStorage {
  AlarmSnapshot snapshot = const AlarmSnapshot();
  bool failLoad = false;
  bool failSave = false;
  int saves = 0;

  @override
  Future<AlarmSnapshot> load() async {
    if (failLoad) throw StateError('Corrupt storage');
    return snapshot;
  }

  @override
  Future<void> save(AlarmSnapshot value) async {
    if (failSave) throw StateError('Storage full');
    saves++;
    snapshot = AlarmSnapshot(
      alarms: [...value.alarms],
      events: [...value.events],
      deviceCheck: value.deviceCheck,
    );
  }
}

class FakeAlarmGateway implements AlarmGateway {
  bool supported = true;
  bool rejectSchedule = false;
  final nativeAlarms = <String, Alarm>{};
  final scheduleCalls = <Alarm>[];
  final cancelCalls = <String>[];
  final snoozeCalls = <String>[];
  final dismissCalls = <String>[];
  final acknowledged = <String>[];
  final pendingEvents = <AlarmEvent>[];
  RingingAlarm? ringing;
  Future<void> Function()? beforeSchedule;
  void Function(List<String>)? beforeAck;

  @override
  Future<AlarmDeviceStatus> status() async => AlarmDeviceStatus(
    platform: supported ? 'android' : 'preview',
    supported: supported,
    exactAlarms: supported,
    notifications: supported,
    fullScreenIntent: supported,
    alarms: nativeAlarms.values.toList(),
  );

  @override
  Future<void> requestPermissions({String? target}) async {}

  @override
  Future<AlarmResult> schedule(Alarm alarm) async {
    scheduleCalls.add(alarm);
    await beforeSchedule?.call();
    if (rejectSchedule) {
      return const AlarmResult(ok: false, error: 'Разрешение не предоставлено');
    }
    final next = alarm.enabled
        ? alarm.nextOccurrence(DateTime(2026, 10, 13, 20))
        : null;
    nativeAlarms[alarm.id] = alarm.copyWith(
      nextAt: next,
      clearNextAt: !alarm.enabled,
    );
    return AlarmResult(ok: true, nextAt: next);
  }

  @override
  Future<AlarmResult> cancel(String id) async {
    cancelCalls.add(id);
    final old = nativeAlarms[id];
    if (old != null) {
      nativeAlarms[id] = old.copyWith(enabled: false, clearNextAt: true);
    }
    return const AlarmResult(ok: true);
  }

  @override
  Future<AlarmResult> snooze(String id) async {
    snoozeCalls.add(id);
    ringing = null;
    return const AlarmResult(ok: true);
  }

  @override
  Future<AlarmResult> dismiss(String id, {bool emergency = false}) async {
    dismissCalls.add(id);
    ringing = null;
    return const AlarmResult(ok: true);
  }

  @override
  Future<AlarmResult> testAlarm(String id, {int delaySeconds = 5}) async =>
      const AlarmResult(ok: true);

  @override
  Future<AlarmResult> cancelTestAlarm(String id) async =>
      const AlarmResult(ok: true);

  @override
  Future<RingingAlarm?> getRingingAlarm() async => ringing;

  @override
  Future<List<AlarmEvent>> drainEvents() async => [...pendingEvents];

  @override
  Future<void> ackEvents(List<String> eventIds) async {
    beforeAck?.call(eventIds);
    acknowledged.addAll(eventIds);
    pendingEvents.removeWhere((event) => eventIds.contains(event.eventId));
  }
}
