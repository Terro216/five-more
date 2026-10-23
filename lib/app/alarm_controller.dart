import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/alarm.dart';
import '../models/device_alarm_check.dart';
import '../services/alarm_gateway.dart';
import '../services/alarm_storage.dart';

class AlarmController extends ChangeNotifier {
  AlarmController({
    required this.gateway,
    required this.storage,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final AlarmGateway gateway;
  final AlarmStorage storage;
  final DateTime Function() _now;
  DateTime get now => _now();
  DeviceAlarmCheck? deviceCheck;

  List<Alarm> _alarms = [];
  List<AlarmEvent> _events = [];
  List<Alarm> get alarms => List.unmodifiable(_alarms);
  List<AlarmEvent> get events => List.unmodifiable(_events.reversed);
  AlarmDeviceStatus device = const AlarmDeviceStatus();
  RingingAlarm? ringing;
  bool loading = true;
  bool busy = false;
  bool storageHealthy = true;
  String? error;
  bool _disposed = false;
  bool _pollPending = false;
  Future<void> _queue = Future.value();
  Timer? _timer;

  Future<void> initialize({bool startPolling = true}) async {
    try {
      final snapshot = await storage.load();
      _alarms = [...snapshot.alarms];
      _events = [...snapshot.events];
      deviceCheck = snapshot.deviceCheck;
    } catch (_) {
      storageHealthy = false;
      error =
          'Не удалось прочитать сохранённые настройки. '
          'Перезапустите приложение: существующие данные не перезаписаны.';
    }
    try {
      device = await gateway.status();
      await _recoverNativeCheck();
      if (device.supported) {
        await _refreshNative();
        if (storageHealthy) await _mergeNativeConfigs();
      }
    } catch (_) {
      error ??= 'Не удалось проверить системный будильник. Попробуйте обновить статус.';
    }
    loading = false;
    _notify();
    if (startPolling) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => poll());
    }
  }

  void setForeground(bool foreground) {
    _timer?.cancel();
    _timer = null;
    if (foreground && !_disposed) {
      unawaited(refreshStatus());
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => poll());
    }
  }

  Future<T> _enqueue<T>(Future<T> Function() action, {bool mutation = false}) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      if (mutation) {
        busy = true;
        error = null;
        _notify();
      }
      try {
        completer.complete(await action());
      } catch (exception, stack) {
        completer.completeError(exception, stack);
      } finally {
        if (mutation) {
          busy = false;
          _notify();
        }
      }
    });
    return completer.future;
  }

  Future<AlarmResult> _mutate(
    Future<AlarmResult> Function() action, {
    bool requiresStorage = true,
  }) => _enqueue(() async {
    if (!storageHealthy && requiresStorage) {
      return AlarmResult(ok: false, error: error ?? 'Хранилище недоступно.');
    }
    try {
      final result = await action();
      if (!result.ok) error = result.error ?? 'Не удалось изменить будильник.';
      return result;
    } catch (_) {
      error =
          'Не удалось завершить действие. Проверьте статус будильника '
          'перед тем, как полагаться на него.';
      return AlarmResult(ok: false, error: error);
    }
  }, mutation: true);

  Future<void> _persist() => storage.save(
    AlarmSnapshot(alarms: _alarms, events: _events, deviceCheck: deviceCheck),
  );

  Future<void> _recoverNativeCheck() async {
    final native = device.activeTest;
    if (native == null ||
        native.previewAlarmId == deviceCheck?.previewAlarmId) {
      return;
    }
    // Native scheduling may survive process death before Dart saved its record.
    // Recover only an unconfirmed check, never an inferred successful delivery.
    deviceCheck = native;
    if (!storageHealthy) return;
    try {
      await _persist();
    } catch (_) {
      error = 'Проверка телефона восстановлена, но запись не сохранена. Её можно отменить на экране проверки.';
    }
  }

  Future<AlarmResult> saveAlarm(
    Alarm alarm, {
    bool allowPreviewDraft = true,
  }) => _mutate(() async {
    Alarm saved;
    if (!device.supported) {
      if (!allowPreviewDraft) {
        return const AlarmResult(
          ok: false,
          error: 'Это режим знакомства. Системные будильники здесь недоступны.',
        );
      }
      saved = alarm.copyWith(enabled: false, clearNextAt: true);
    } else {
      final result = await gateway.schedule(alarm);
      if (!result.ok) return result;
      saved = alarm.copyWith(
        nextAt: result.nextAt,
        clearNextAt: !alarm.enabled,
      );
    }
    final index = _alarms.indexWhere((item) => item.id == saved.id);
    if (index < 0) {
      _alarms.add(saved);
    } else {
      _alarms[index] = saved;
    }
    await _persist();
    return AlarmResult(ok: true, alarm: saved, nextAt: saved.nextAt);
  });

  Future<AlarmResult> setEnabled(Alarm alarm, bool enabled) =>
      saveAlarm(alarm.copyWith(enabled: enabled), allowPreviewDraft: false);

  Future<AlarmResult> deleteAlarm(String id) => _mutate(() async {
    if (device.supported) {
      final result = await gateway.cancel(id);
      if (!result.ok) return result;
    }
    _alarms.removeWhere((alarm) => alarm.id == id);
    await _persist();
    return const AlarmResult(ok: true);
  });

  Future<AlarmResult> snooze({String? alarmId, String? occurrenceId}) {
    // Capture the originating screen before queueing: a native timeout may
    // expose another overlapping alarm while this action is waiting its turn.
    final expectedAlarmId = alarmId ?? ringing?.alarm.id;
    final expectedOccurrenceId = occurrenceId ?? ringing?.occurrenceId;
    return _mutate(() async {
      final active = ringing;
      if (active == null ||
          active.alarm.id != expectedAlarmId ||
          active.occurrenceId != expectedOccurrenceId) {
        return const AlarmResult(
          ok: false,
          error: 'Этот подъём уже завершён. Проверьте текущий будильник.',
        );
      }
      if (active.snoozesRemaining <= 0) {
        return const AlarmResult(
          ok: false,
          error: 'На этот подъём переносов больше нет.',
        );
      }
      final result = await gateway.snooze(active.alarm.id);
      if (result.ok) {
        ringing = null;
        await _refreshNative();
      }
      return result;
    }, requiresStorage: false);
  }

  Future<AlarmResult> dismiss({
    bool emergency = false,
    String? alarmId,
    String? occurrenceId,
  }) {
    final expectedAlarmId = alarmId ?? ringing?.alarm.id;
    final expectedOccurrenceId = occurrenceId ?? ringing?.occurrenceId;
    return _mutate(() async {
      final active = ringing;
      if (active == null ||
          active.alarm.id != expectedAlarmId ||
          active.occurrenceId != expectedOccurrenceId) {
        return const AlarmResult(
          ok: false,
          error: 'Этот подъём уже завершён. Проверьте текущий будильник.',
        );
      }
      final result = await gateway.dismiss(
        active.alarm.id,
        emergency: emergency,
      );
      if (result.ok) {
        ringing = null;
        await _refreshNative();
      }
      return result;
    }, requiresStorage: false);
  }

  Future<AlarmResult> testAlarm(String id) => startDeviceCheck(id);

  Future<AlarmResult> startDeviceCheck(
    String sourceAlarmId,
  ) => _mutate(() async {
    if (deviceCheck?.pending == true) {
      return const AlarmResult(
        ok: false,
        error: 'Сначала заверши или отмени текущую проверку звонка.',
      );
    }
    device = await gateway.status();
    await _recoverNativeCheck();
    if (deviceCheck?.pending == true) {
      return const AlarmResult(
        ok: false,
        error: 'На телефоне уже ожидается проверочный звонок. Заверши или отмени его.',
      );
    }
    if (!device.supported) {
      return const AlarmResult(
        ok: false,
        error: 'В режиме знакомства доступна тренировка. Проверять звонок нужно на телефоне.',
      );
    }
    if (!device.canSchedule) {
      return const AlarmResult(
        ok: false,
        error: 'Сначала разреши уведомления и точное срабатывание.',
      );
    }
    if (sourceAlarmId.startsWith('preview:') ||
        !_alarms.any((alarm) => alarm.id == sourceAlarmId)) {
      return const AlarmResult(
        ok: false,
        error: 'Сначала сохрани будильник для проверки.',
      );
    }
    ringing = await gateway.getRingingAlarm();
    if (ringing != null) {
      return const AlarmResult(
        ok: false,
        error: 'Сначала заверши текущий подъём.',
      );
    }
    final startedAt = now;
    final result = await gateway.testAlarm(sourceAlarmId, delaySeconds: 20);
    if (!result.ok) return result;
    final previewId = result.alarm?.id;
    final dueAt = result.nextAt;
    if (previewId == null ||
        !previewId.startsWith('preview:') ||
        dueAt == null ||
        dueAt.isBefore(startedAt)) {
      if (previewId?.startsWith('preview:') == true) {
        await gateway.cancelTestAlarm(previewId!);
      }
      return const AlarmResult(
        ok: false,
        error:
            'Телефон не подтвердил время проверки. Проверь статус будильника.',
      );
    }
    final previous = deviceCheck;
    deviceCheck = DeviceAlarmCheck(
      sourceAlarmId: sourceAlarmId,
      previewAlarmId: previewId,
      startedAt: startedAt,
      dueAt: dueAt,
    );
    try {
      await _persist();
    } catch (_) {
      var cancelled = false;
      try {
        cancelled = (await gateway.cancelTestAlarm(previewId)).ok;
      } catch (_) {
        // Keep the current preview's identity available for the emergency path.
      }
      if (cancelled) deviceCheck = previous;
      return AlarmResult(
        ok: false,
        error: cancelled
            ? 'Проверка отменена: не удалось сохранить её состояние. Освободи место и попробуй снова.'
            : 'Состояние проверки не сохранено, а отмена не подтверждена. Проверочный звонок может сработать; отмени его на этом экране.',
      );
    }
    return result;
  });

  Future<AlarmResult> finishDeviceCheck({
    required bool heard,
    String? previewAlarmId,
  }) {
    final expectedId = previewAlarmId ?? deviceCheck?.previewAlarmId;
    return _mutate(() async {
      final check = deviceCheck;
      if (check == null ||
          !check.pending ||
          check.previewAlarmId != expectedId) {
        return const AlarmResult(
          ok: false,
          error: 'Эта проверка уже завершена или заменена новой.',
        );
      }
      if (!check.canConfirm(now)) {
        return const AlarmResult(
          ok: false,
          error: 'Дождись времени проверочного звонка.',
        );
      }
      // Also cancels a late or snoozed preview. Never resolve the real schedule.
      final cancelled = await gateway.cancelTestAlarm(check.previewAlarmId);
      if (!cancelled.ok) return cancelled;
      final confirmed = check.confirmed(heard: heard, at: now);
      await storage.save(
        AlarmSnapshot(alarms: _alarms, events: _events, deviceCheck: confirmed),
      );
      deviceCheck = confirmed;
      ringing = await gateway.getRingingAlarm();
      return const AlarmResult(ok: true);
    });
  }

  Future<AlarmResult> cancelDeviceCheck({String? previewAlarmId}) {
    final expectedId = previewAlarmId ?? deviceCheck?.previewAlarmId;
    return _mutate(() async {
      final check = deviceCheck;
      if (check == null ||
          !check.pending ||
          check.previewAlarmId != expectedId) {
        return const AlarmResult(
          ok: false,
          error: 'Эта проверка уже завершена или заменена новой.',
        );
      }
      final result = await gateway.cancelTestAlarm(check.previewAlarmId);
      if (!result.ok) return result;
      // Silence/cancellation succeeds even when saving the UI record does not.
      deviceCheck = null;
      ringing = await gateway.getRingingAlarm();
      if (!storageHealthy) {
        return const AlarmResult(
          ok: false,
          error: 'Проверочный звонок отменён. Хранилище недоступно; прежние данные не перезаписаны.',
        );
      }
      try {
        await _persist();
      } catch (_) {
        return const AlarmResult(
          ok: false,
          error: 'Проверочный звонок отменён, но запись об отмене не сохранена. Проверь свободное место.',
        );
      }
      return result;
    }, requiresStorage: false);
  }

  Future<void> requestPermissions({String? target}) => _enqueue(() async {
    try {
      await gateway.requestPermissions(target: target);
      device = await gateway.status();
      await _recoverNativeCheck();
      if (storageHealthy) await _mergeNativeConfigs();
      error = null;
    } catch (_) {
      error =
          'Не удалось открыть системные разрешения. '
          'Проверьте их в настройках приложения.';
    }
    _notify();
  });

  Future<AlarmResult> restoreAlarms() => _mutate(() async {
    if (!device.supported || device.bootRecoverySupported != true) {
      return const AlarmResult(
        ok: false,
        error: 'Восстановление расписания здесь недоступно.',
      );
    }
    final result = await gateway.restoreAlarms();
    device = await gateway.status();
    if (storageHealthy) await _mergeNativeConfigs();
    if (result.ok &&
        (!device.supported ||
            device.error != null ||
            device.recoveryError != null)) {
      return AlarmResult(
        ok: false,
        error:
            device.recoveryError ??
            device.error ??
            'Не удалось подтвердить восстановление расписания. Обнови статус.',
      );
    }
    return result;
  }, requiresStorage: false);

  Future<void> refreshStatus() => _enqueue(() async {
    try {
      device = await gateway.status();
      await _recoverNativeCheck();
      if (device.supported) {
        await _refreshNative();
        if (storageHealthy) await _mergeNativeConfigs();
      }
    } catch (_) {
      error = 'Не удалось обновить статус системного будильника.';
    }
    _notify();
  });

  Future<void> poll() async {
    if (_disposed || loading || _pollPending || !device.supported) return;
    _pollPending = true;
    try {
      await _enqueue(() async {
        await _refreshNative();
        _notify();
      });
    } catch (_) {
      error = 'Связь с системным будильником временно недоступна.';
      _notify();
    } finally {
      _pollPending = false;
    }
  }

  Future<void> _refreshNative() async {
    // Alarm controls must remain usable even if local history cannot be read or
    // written. Native scheduling/audio are independent of this UI storage.
    ringing = await gateway.getRingingAlarm();
    if (!storageHealthy) return;
    // Native keeps pending entries until local storage succeeds. Replays after
    // process death or a failed acknowledgement are deduplicated by event ID.
    final incoming = await gateway.drainEvents();
    if (incoming.isNotEmpty) {
      final known = _events.map((event) => event.eventId).toSet();
      for (final event in incoming) {
        if (event.alarmId.startsWith('preview:')) continue;
        if (!known.add(event.eventId)) continue;
        _events.add(event);
        final index = _alarms.indexWhere((alarm) => alarm.id == event.alarmId);
        if (index < 0) continue;
        final alarm = _alarms[index];
        final finished = const [
          'dismissed',
          'emergency_dismissed',
          'emergency',
          'timed_out',
          'cancelled',
        ].contains(event.type);
        if (finished && alarm.weekdays.isEmpty) {
          _alarms[index] = alarm.copyWith(enabled: false, clearNextAt: true);
        } else if (event.nextAt != null) {
          _alarms[index] = alarm.copyWith(nextAt: event.nextAt);
        } else if (finished ||
            event.type == 'fired' ||
            event.type == 'ringing') {
          if (alarm.weekdays.isNotEmpty) {
            _alarms[index] = alarm.copyWith(
              nextAt: alarm.nextOccurrence(event.at),
            );
          }
        }
      }
      _events.sort((a, b) => a.at.compareTo(b.at));
      if (_events.length > 500) _events = _events.sublist(_events.length - 500);
      try {
        await _persist();
        await gateway.ackEvents(
          incoming.map((event) => event.eventId).toList(),
        );
        device = await gateway.status();
        await _mergeNativeConfigs();
      } catch (_) {
        error =
            'История пока не сохранена. Будильник продолжает работать; '
            'события будут загружены повторно.';
      }
    }
  }

  Future<void> _mergeNativeConfigs() async {
    if (device.alarms.isEmpty) return;
    var changed = false;
    for (final native in device.alarms) {
      if (native.id.startsWith('preview:')) continue;
      final index = _alarms.indexWhere((alarm) => alarm.id == native.id);
      if (index < 0) {
        // cancel retains a disabled native record. Do not resurrect a draft
        // that the user intentionally deleted from the application.
        if (!native.enabled) continue;
        _alarms.add(native);
        changed = true;
      } else if (_alarms[index].toJson().toString() !=
          native.toJson().toString()) {
        _alarms[index] = native;
        changed = true;
      }
    }
    if (changed) await _persist();
  }

  Alarm? nextAlarm(DateTime now) {
    final upcoming = _alarms.where((alarm) => alarm.enabled).toList();
    if (upcoming.isEmpty) return null;
    upcoming.sort((a, b) => nextTime(a, now).compareTo(nextTime(b, now)));
    return upcoming.first;
  }

  DateTime nextTime(Alarm alarm, DateTime now) =>
      alarm.nextAt?.isAfter(now) == true
      ? alarm.nextAt!
      : alarm.nextOccurrence(now);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
