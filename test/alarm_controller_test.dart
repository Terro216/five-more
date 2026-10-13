import 'dart:async';

import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/models/alarm.dart';
import 'package:five_more/services/alarm_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'alarm_fakes.dart';

void main() {
  late FakeAlarmGateway gateway;
  late MemoryAlarmStorage storage;
  late AlarmController controller;
  const alarm = Alarm(id: 'a', hour: 7, minute: 30);

  setUp(() {
    gateway = FakeAlarmGateway();
    storage = MemoryAlarmStorage();
    controller = AlarmController(gateway: gateway, storage: storage);
  });
  tearDown(() => controller.dispose());

  test('startup restores configs without rescheduling native alarms', () async {
    storage.snapshot = const AlarmSnapshot(alarms: [alarm]);
    gateway.nativeAlarms[alarm.id] = alarm;
    await controller.initialize(startPolling: false);
    expect(controller.alarms, hasLength(1));
    expect(gateway.scheduleCalls, isEmpty);
  });

  test('schedule denial never presents a newly enabled alarm', () async {
    await controller.initialize(startPolling: false);
    gateway.rejectSchedule = true;
    final result = await controller.saveAlarm(alarm);
    expect(result.ok, isFalse);
    expect(controller.alarms, isEmpty);
    expect(storage.snapshot.alarms, isEmpty);
  });

  test('preview drafts are explicitly disabled and do not invoke native scheduling', () async {
    gateway.supported = false;
    await controller.initialize(startPolling: false);
    expect((await controller.saveAlarm(alarm)).ok, isTrue);
    expect(controller.alarms.single.enabled, isFalse);
    expect(
      (await controller.setEnabled(controller.alarms.single, true)).ok,
      isFalse,
    );
    expect(gateway.scheduleCalls, isEmpty);
  });

  test(
    'disabled edits update native configuration and survive refresh',
    () async {
      final disabled = alarm.copyWith(enabled: false);
      storage.snapshot = AlarmSnapshot(alarms: [disabled]);
      gateway.nativeAlarms[alarm.id] = disabled;
      await controller.initialize(startPolling: false);
      await controller.saveAlarm(disabled.copyWith(hour: 9));
      await controller.refreshStatus();
      expect(controller.alarms.single.hour, 9);
      expect(controller.alarms.single.enabled, isFalse);
      expect(gateway.cancelCalls, isEmpty);
    },
  );

  test(
    'deleted disabled native leftovers are not restored as UI alarms',
    () async {
      storage.snapshot = const AlarmSnapshot(alarms: [alarm]);
      gateway.nativeAlarms[alarm.id] = alarm;
      await controller.initialize(startPolling: false);
      await controller.deleteAlarm(alarm.id);
      await controller.refreshStatus();
      expect(controller.alarms, isEmpty);
      expect(gateway.nativeAlarms[alarm.id]!.enabled, isFalse);
    },
  );

  test(
    'mutations serialize across native calls and final persisted state',
    () async {
      await controller.initialize(startPolling: false);
      final gate = Completer<void>();
      var calls = 0;
      gateway.beforeSchedule = () async {
        calls++;
        if (calls == 1) await gate.future;
      };
      final first = controller.saveAlarm(alarm.copyWith(hour: 8));
      final second = controller.saveAlarm(alarm.copyWith(hour: 9));
      await Future<void>.delayed(Duration.zero);
      expect(gateway.scheduleCalls, hasLength(1));
      gate.complete();
      await Future.wait([first, second]);
      expect(gateway.scheduleCalls, hasLength(2));
      expect(storage.snapshot.alarms.single.hour, 9);
    },
  );

  test('pending events are saved before acknowledgement and replay is deduplicated', () async {
    final event = AlarmEvent(
      eventId: 'event',
      alarmId: 'a',
      occurrenceId: 'morning',
      type: 'snoozed',
      at: DateTime(2026, 10, 13, 7, 30),
      snoozesUsed: 1,
    );
    gateway.pendingEvents.addAll([event, event]);
    gateway.beforeAck = (_) => expect(storage.snapshot.events, hasLength(1));
    await controller.initialize(startPolling: false);
    expect(controller.events, hasLength(1));
    expect(gateway.pendingEvents, isEmpty);
  });

  test(
    'storage write failure leaves events unacknowledged and ringing usable',
    () async {
      gateway.ringing = RingingAlarm(
        alarm: alarm,
        occurrenceId: 'morning',
        firedAt: DateTime(2026, 10, 13, 7, 30),
        snoozesUsed: 0,
      );
      gateway.pendingEvents.add(
        AlarmEvent(
          eventId: 'pending',
          alarmId: 'a',
          occurrenceId: 'morning',
          type: 'fired',
          at: DateTime(2026, 10, 13, 7, 30),
        ),
      );
      storage.failSave = true;
      await controller.initialize(startPolling: false);
      expect(controller.ringing, isNotNull);
      expect(gateway.acknowledged, isEmpty);
      expect((await controller.dismiss(emergency: true)).ok, isTrue);
      expect(gateway.dismissCalls, ['a']);
      storage.failSave = false;
      await controller.poll();
      expect(storage.snapshot.events, hasLength(1));
      expect(gateway.pendingEvents, isEmpty);
    },
  );

  test('corrupt application storage cannot hide a ringing alarm or block emergency stop', () async {
    storage.failLoad = true;
    gateway.ringing = RingingAlarm(
      alarm: alarm,
      occurrenceId: 'morning',
      firedAt: DateTime(2026, 10, 13, 7, 30),
      snoozesUsed: 1,
    );
    await controller.initialize(startPolling: false);
    expect(controller.storageHealthy, isFalse);
    expect(controller.ringing, isNotNull);
    expect((await controller.dismiss(emergency: true)).ok, isTrue);
    expect(gateway.dismissCalls, ['a']);
  });

  test('reopening app cannot reset the native snooze allowance', () async {
    gateway.ringing = RingingAlarm(
      alarm: alarm,
      occurrenceId: 'morning',
      firedAt: DateTime(2026, 10, 13, 7, 30),
      snoozesUsed: 3,
    );
    await controller.initialize(startPolling: false);
    expect((await controller.snooze()).ok, isFalse);
    expect(gateway.snoozeCalls, isEmpty);
    expect(controller.ringing!.snoozesRemaining, 0);
  });

  for (final action in ['dismiss', 'snooze']) {
    test('queued $action cannot affect the next overlapping alarm', () async {
      gateway.ringing = RingingAlarm(
        alarm: alarm,
        occurrenceId: 'first-morning',
        firedAt: DateTime(2026, 10, 13, 7, 30),
        snoozesUsed: 0,
      );
      await controller.initialize(startPolling: false);
      final gate = Completer<void>();
      gateway.beforeSchedule = () => gate.future;
      final blocker = controller.saveAlarm(
        const Alarm(id: 'unrelated-setting', hour: 9, minute: 0),
      );
      await Future<void>.delayed(Duration.zero);
      final pendingRefresh = controller.poll();
      final pendingAction = action == 'dismiss'
          ? controller.dismiss()
          : controller.snooze();
      gateway.ringing = RingingAlarm(
        alarm: const Alarm(id: 'second-alarm', hour: 7, minute: 31),
        occurrenceId: 'second-morning',
        firedAt: DateTime(2026, 10, 13, 7, 31),
        snoozesUsed: 0,
      );
      gate.complete();
      await blocker;
      await pendingRefresh;
      expect((await pendingAction).ok, isFalse);
      expect(gateway.dismissCalls, isEmpty);
      expect(gateway.snoozeCalls, isEmpty);
      expect(controller.ringing!.alarm.id, 'second-alarm');
    });
  }

  test(
    'old screen identity cannot dismiss a new occurrence of the same alarm',
    () async {
      gateway.ringing = RingingAlarm(
        alarm: alarm,
        occurrenceId: 'new-morning',
        firedAt: DateTime(2026, 10, 14, 7, 30),
        snoozesUsed: 0,
      );
      await controller.initialize(startPolling: false);
      final result = await controller.dismiss(
        alarmId: alarm.id,
        occurrenceId: 'old-morning',
      );
      expect(result.ok, isFalse);
      expect(gateway.dismissCalls, isEmpty);
      expect(controller.ringing!.occurrenceId, 'new-morning');
    },
  );
}
