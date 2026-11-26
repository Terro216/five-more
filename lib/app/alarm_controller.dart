import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../l10n/strings.dart';
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
  List<AlarmEvent> sleepEvents = [];
  Future<void> _refreshSleepEvents() async {
    sleepEvents = await storage.eventsBetween(
      now.subtract(const Duration(hours: 54)),
      now.add(const Duration(seconds: 1)),
    );
  }

  List<Alarm> get alarms => List.unmodifiable(_alarms);
  List<AlarmEvent> get events => List.unmodifiable(_events.reversed);
  AlarmDeviceStatus device = const AlarmDeviceStatus();
  RingingAlarm? ringing;
  List<RingingAlarm> snoozedAlarms = [];
  RingingAlarm? activeOccurrence(String id) => ringing?.alarm.id == id
      ? ringing
      : snoozedAlarms.where((active) => active.alarm.id == id).firstOrNull;
  bool loading = true;
  bool nativeStateKnown = false;
  bool busy = false;
  final Set<String> _pendingAlarmIds = {};
  bool isAlarmBusy(String id) => _pendingAlarmIds.contains(id);
  Alarm? alarmById(String id) => _alarms.where((a) => a.id == id).firstOrNull;
  Future<AlarmResult> _forAlarm(
    String id,
    Future<AlarmResult> Function() action,
  ) async {
    if (!_pendingAlarmIds.add(id)) {
      return AlarmResult(
        ok: false,
        error: appStrings.waitForThisAlarmToFinishUpdating,
      );
    }
    _notify();
    try {
      return await action();
    } finally {
      _pendingAlarmIds.remove(id);
      _notify();
    }
  }

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
      await _refreshSleepEvents();
    } catch (_) {
      storageHealthy = false;
      error = appStrings.savedSettingsReadError;
    }
    try {
      device = await gateway.status();
      await _recoverNativeCheck();
      if (device.supported) {
        await _refreshNative();
        if (storageHealthy) await _mergeNativeConfigs();
      }
    } catch (_) {
      error ??= appStrings.systemAlarmCheckError;
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
    if (!foreground) {
      nativeStateKnown = false;
      _notify();
    }
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
      return AlarmResult(
        ok: false,
        error: error ?? appStrings.storageIsUnavailable,
      );
    }
    try {
      final result = await action();
      if (!result.ok) error = result.error ?? appStrings.couldntUpdateTheAlarm;
      return result;
    } catch (_) {
      error = appStrings.alarmActionFailed;
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
      error = appStrings.restoredTestNotSaved;
    }
  }

  Future<AlarmResult> saveAlarm(Alarm alarm, {bool allowPreviewDraft = true}) =>
      _forAlarm(
        alarm.id,
        () => _saveAlarm(alarm, allowPreviewDraft: allowPreviewDraft),
      );

  Future<AlarmResult> _saveAlarm(
    Alarm alarm, {
    bool allowPreviewDraft = true,
    bool? enabledOverride,
  }) => _mutate(() async {
    if (enabledOverride != null) {
      final current = alarmById(alarm.id);
      if (current == null) {
        return AlarmResult(
          ok: false,
          error: appStrings.thisAlarmHasAlreadyBeenDeleted,
        );
      }
      alarm = current.copyWith(enabled: enabledOverride);
    }
    alarm = alarm.copyWith(configurationId: newAlarmId());
    if (alarm.enabled) alarm = alarm.copyWith(armedAt: now);
    Alarm saved;
    if (!device.supported) {
      if (!allowPreviewDraft) {
        return AlarmResult(
          ok: false,
          error: appStrings.youreInPreviewModeSystemAlarmsAre,
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
    if (saved.enabled && !saved.id.startsWith('preview:')) {
      final id = newAlarmId();
      _events.add(
        AlarmEvent(
          eventId: id,
          alarmId: saved.id,
          occurrenceId: 'setup:$id',
          type: 'armed',
          at: now,
          nextAt: saved.nextAt,
        ),
      );
    }
    await _persist();
    return AlarmResult(ok: true, alarm: saved, nextAt: saved.nextAt);
  });

  Future<AlarmResult> setEnabled(Alarm alarm, bool enabled) => _forAlarm(
    alarm.id,
    () => _saveAlarm(alarm, enabledOverride: enabled, allowPreviewDraft: false),
  );

  Future<AlarmResult> deleteAlarm(String id) => _forAlarm(
    id,
    () => _mutate(() async {
      if (device.supported) {
        final result = await gateway.cancel(id);
        if (!result.ok) return result;
      }
      _alarms.removeWhere((alarm) => alarm.id == id);
      await _persist();
      return const AlarmResult(ok: true);
    }),
  );

  Future<AlarmResult> quiet(RingingAlarm source) => _mutate(() async {
    final current = await gateway.getRingingAlarm();
    if (current == null ||
        current.occurrenceId != source.occurrenceId ||
        current.snoozesUsed != source.snoozesUsed) {
      return AlarmResult(
        ok: false,
        error: appStrings.thisAlarmHasAlreadyStoppedRinging,
      );
    }
    final result = await gateway.quiet(
      source.alarm.id,
      source.occurrenceId,
      source.snoozesUsed,
    );
    ringing = await gateway.getRingingAlarm();
    return result;
  }, requiresStorage: false);

  Future<AlarmResult> snooze({
    String? alarmId,
    String? occurrenceId,
    int? minutes,
  }) {
    // Capture the originating screen before queueing: a native timeout may
    // expose another overlapping alarm while this action is waiting its turn.
    final expectedAlarmId = alarmId ?? ringing?.alarm.id;
    final expectedOccurrenceId = occurrenceId ?? ringing?.occurrenceId;
    return _mutate(() async {
      final active = ringing;
      if (active == null ||
          active.alarm.id != expectedAlarmId ||
          active.occurrenceId != expectedOccurrenceId) {
        return AlarmResult(ok: false, error: appStrings.alarmEndedCheckCurrent);
      }
      if (active.minutesRemaining <= 0) {
        return AlarmResult(ok: false, error: appStrings.noSnoozeTimeLeft);
      }
      if (minutes != null &&
          (minutes < 1 || minutes > active.minutesRemaining || minutes > 30)) {
        return AlarmResult(
          ok: false,
          error: appStrings.chooseASnoozeWithinYourRemainingTime,
        );
      }
      final result = await gateway.snooze(
        active.alarm.id,
        minutes: minutes ?? active.defaultSnoozeMinutes,
      );
      if (result.ok) {
        ringing = null;
        await _refreshNative();
      }
      return result;
    }, requiresStorage: false);
  }

  Future<AlarmResult> dismiss({
    bool emergency = false,
    bool disableAlarm = false,
    String? alarmId,
    String? occurrenceId,
    int? generation,
  }) {
    final expectedAlarmId = alarmId ?? ringing?.alarm.id;
    final expectedOccurrenceId = occurrenceId ?? ringing?.occurrenceId;
    return _mutate(() async {
      final active = expectedAlarmId == null
          ? null
          : activeOccurrence(expectedAlarmId);
      if (active == null ||
          active.alarm.id != expectedAlarmId ||
          active.occurrenceId != expectedOccurrenceId ||
          (generation != null && active.snoozesUsed != generation)) {
        return AlarmResult(ok: false, error: appStrings.alarmEndedCheckCurrent);
      }
      final result = await gateway.dismiss(
        active.alarm.id,
        emergency: emergency,
        occurrenceId: active.occurrenceId,
        generation: active.snoozesUsed,
      );
      if (result.ok) {
        if (ringing?.occurrenceId == active.occurrenceId) ringing = null;
        snoozedAlarms.removeWhere((a) => a.occurrenceId == active.occurrenceId);
        AlarmResult? disabled;
        if (disableAlarm) {
          try {
            disabled = await gateway.cancel(active.alarm.id);
          } catch (_) {
            disabled = const AlarmResult(ok: false);
          }
        }
        try {
          await _refreshNative();
          device = await gateway.status();
          if (storageHealthy) await _mergeNativeConfigs();
        } catch (_) {
          error = appStrings.dismissedRefreshPending;
        }
        if (disabled != null && !disabled.ok) {
          return AlarmResult(
            ok: false,
            error: appStrings.alarmDismissedScheduleError(
              disabled.error ?? appStrings.checkTheSchedule,
            ),
          );
        }
      }
      return result;
    }, requiresStorage: false);
  }

  Future<AlarmResult> testAlarm(String id) => startDeviceCheck(id);

  Future<AlarmResult> startDeviceCheck(
    String sourceAlarmId, {
    int delaySeconds = 20,
  }) => _mutate(() async {
    if (delaySeconds < 1 || delaySeconds > 60) {
      return AlarmResult(
        ok: false,
        error: appStrings.chooseBetween1And60Seconds,
      );
    }
    if (deviceCheck?.pending == true) {
      return AlarmResult(
        ok: false,
        error: appStrings.finishOrCancelTheCurrentAlarmTest,
      );
    }
    device = await gateway.status();
    await _recoverNativeCheck();
    if (deviceCheck?.pending == true) {
      return AlarmResult(ok: false, error: appStrings.testAlarmAlreadyPending);
    }
    if (!device.supported) {
      return AlarmResult(
        ok: false,
        error: appStrings.phoneRequiredForAlarmTest,
      );
    }
    if (!device.canSchedule) {
      return AlarmResult(
        ok: false,
        error: appStrings.allowNotificationsAndExactAlarmsFirst,
      );
    }
    if (sourceAlarmId.startsWith('preview:') ||
        !_alarms.any((alarm) => alarm.id == sourceAlarmId)) {
      return AlarmResult(
        ok: false,
        error: appStrings.saveAnAlarmBeforeTestingIt,
      );
    }
    ringing = await gateway.getRingingAlarm();
    nativeStateKnown = true;
    if (ringing != null) {
      return AlarmResult(
        ok: false,
        error: appStrings.dismissTheCurrentAlarmFirst,
      );
    }
    final startedAt = now;
    final result = await gateway.testAlarm(
      sourceAlarmId,
      delaySeconds: delaySeconds,
    );
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
      return AlarmResult(
        ok: false,
        error: appStrings.yourPhoneDidntConfirmTheTestTime,
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
            ? appStrings.testCanceledStorageError
            : appStrings.testCancellationUnconfirmed,
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
        return AlarmResult(
          ok: false,
          error: appStrings.thisTestHasAlreadyEndedOrBeen,
        );
      }
      if (!check.canConfirm(now)) {
        return AlarmResult(
          ok: false,
          error: appStrings.waitForTheTestAlarmToRing,
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
      nativeStateKnown = true;
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
        return AlarmResult(
          ok: false,
          error: appStrings.thisTestHasAlreadyEndedOrBeen,
        );
      }
      final result = await gateway.cancelTestAlarm(check.previewAlarmId);
      if (!result.ok) return result;
      // Silence/cancellation succeeds even when saving the UI record does not.
      deviceCheck = null;
      ringing = await gateway.getRingingAlarm();
      nativeStateKnown = true;
      if (!storageHealthy) {
        return AlarmResult(
          ok: false,
          error: appStrings.testCanceledStorageUnavailable,
        );
      }
      try {
        await _persist();
      } catch (_) {
        return AlarmResult(
          ok: false,
          error: appStrings.testCancellationSaveError,
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
      error = appStrings.openPermissionsError;
    }
    _notify();
  });

  Future<AlarmResult> restoreAlarms() => _mutate(() async {
    if (!device.supported || device.bootRecoverySupported != true) {
      return AlarmResult(
        ok: false,
        error: appStrings.scheduleRecoveryIsUnavailableHere,
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
            appStrings.scheduleRestoreUnconfirmed,
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
      error = appStrings.systemAlarmStatusError;
    }
    _notify();
  });

  Future<void> poll() async {
    if (_disposed || loading || _pollPending || !device.supported) return;
    _pollPending = true;
    try {
      await _enqueue(() async {
        final before = _visibleState();
        await _refreshNative();
        if (before != _visibleState()) _notify();
      });
    } catch (_) {
      error = appStrings.systemAlarmUnavailable;
      _notify();
    } finally {
      _pollPending = false;
    }
  }

  String _visibleState() => jsonEncode({
    'alarms': _alarms.map((a) => a.toJson()).toList(),
    'events': _events.map((e) => e.eventId).toList(),
    'ring': ringing == null
        ? null
        : [
            ringing!.occurrenceId,
            ringing!.snoozesUsed,
            ringing!.quietUsed,
            ringing!.quietRemainingSeconds,
            ringing!.alarm.toJson(),
          ],
    'known': nativeStateKnown,
    'snoozed': snoozedAlarms
        .map(
          (a) => [
            a.alarm.id,
            a.occurrenceId,
            a.snoozesUsed,
            a.snoozedUntil?.millisecondsSinceEpoch,
          ],
        )
        .toList(),
    'error': error,
  });

  Future<void> _refreshNative() async {
    // Alarm controls must remain usable even if local history cannot be read or
    // written. Native scheduling/audio are independent of this UI storage.
    ringing = await gateway.getRingingAlarm();
    snoozedAlarms = await gateway.getSnoozedAlarms();
    nativeStateKnown = true;
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
        if (alarm.configurationId.isNotEmpty &&
            alarm.configurationId != event.configurationId) {
          continue;
        }
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
      try {
        await _persist();
        // First commit history, then remove only the exact configuration that
        // produced a final dismissal. Replays run this even for known events.
        final beforeCleanup = [..._alarms];
        _alarms.removeWhere(
          (alarm) =>
              alarm.weekdays.isEmpty &&
              alarm.deleteAfterDismiss &&
              alarm.configurationId.isNotEmpty &&
              incoming.any(
                (event) =>
                    !event.alarmId.startsWith('preview:') &&
                    event.alarmId == alarm.id &&
                    event.configurationId == alarm.configurationId &&
                    const [
                      'dismissed',
                      'emergency_dismissed',
                      'emergency',
                    ].contains(event.type),
              ),
        );
        if (_alarms.length != beforeCleanup.length) {
          try {
            await _persist();
          } catch (_) {
            _alarms = beforeCleanup;
            rethrow;
          }
        }
        await gateway.ackEvents(
          incoming.map((event) => event.eventId).toList(),
        );
        device = await gateway.status();
        await _mergeNativeConfigs();
        await _refreshSleepEvents();
      } catch (_) {
        error = appStrings.historySavePending;
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
