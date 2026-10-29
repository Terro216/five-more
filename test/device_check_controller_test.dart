import 'package:five_more/services/local_database.dart';

import 'dart:convert';

import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/models/alarm.dart';
import 'package:five_more/models/device_alarm_check.dart';
import 'package:five_more/services/alarm_gateway.dart';
import 'package:five_more/services/alarm_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'alarm_fakes.dart';

const deviceCheckSourceAlarm = Alarm(
  id: 'actual-morning',
  hour: 7,
  minute: 30,
  weekdays: [1, 2, 3, 4, 5],
);

/// The platform returns a separate occurrence; it never borrows the real ID.
class DeviceCheckGateway extends FakeAlarmGateway {
  DateTime currentTime = DateTime(2026, 10, 22, 20);
  bool rejectTest = false;
  bool rejectCancelTest = false;
  DeviceAlarmCheck? activeTest;
  final testCalls = <({String id, int delaySeconds})>[];
  final cancelTestCalls = <String>[];

  @override
  Future<AlarmDeviceStatus> status() async {
    final original = await super.status();
    return AlarmDeviceStatus(
      platform: original.platform,
      supported: original.supported,
      exactAlarms: original.exactAlarms,
      notifications: original.notifications,
      fullScreenIntent: original.fullScreenIntent,
      alarms: original.alarms,
      activeTest: activeTest,
    );
  }

  @override
  Future<AlarmResult> testAlarm(String id, {int delaySeconds = 5}) async {
    testCalls.add((id: id, delaySeconds: delaySeconds));
    if (rejectTest) {
      return const AlarmResult(ok: false, error: 'Точная доставка запрещена');
    }
    final nextAt = currentTime.add(Duration(seconds: delaySeconds));
    return AlarmResult(
      ok: true,
      nextAt: nextAt,
      alarm: Alarm(
        id: 'preview:device-check-${testCalls.length}',
        hour: currentTime.hour,
        minute: currentTime.minute,
        nextAt: nextAt,
      ),
    );
  }

  @override
  Future<AlarmResult> cancelTestAlarm(String id) async {
    cancelTestCalls.add(id);
    if (!rejectCancelTest && activeTest?.previewAlarmId == id) {
      activeTest = null;
    }
    return AlarmResult(
      ok: !rejectCancelTest,
      error: rejectCancelTest ? 'Не удалось отменить пробный звонок' : null,
    );
  }
}

class DeviceCheckStorage extends MemoryAlarmStorage {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DeviceCheckGateway gateway;
  late DeviceCheckStorage storage;
  late AlarmController controller;

  setUp(() {
    gateway = DeviceCheckGateway();
    gateway.nativeAlarms[deviceCheckSourceAlarm.id] = deviceCheckSourceAlarm;
    storage = DeviceCheckStorage()
      ..snapshot = const AlarmSnapshot(alarms: [deviceCheckSourceAlarm]);
    controller = AlarmController(
      gateway: gateway,
      storage: storage,
      now: () => gateway.currentTime,
    );
  });
  tearDown(() => controller.dispose());

  test(
    'native pending test survives a crash before the Dart checkpoint',
    () async {
      gateway.activeTest = DeviceAlarmCheck(
        sourceAlarmId: deviceCheckSourceAlarm.id,
        previewAlarmId: 'preview:recovered',
        startedAt: gateway.currentTime,
        dueAt: gateway.currentTime.add(const Duration(seconds: 20)),
      );
      await controller.initialize(startPolling: false);
      expect(controller.deviceCheck!.previewAlarmId, 'preview:recovered');
      expect(controller.deviceCheck!.heard, isNull);
      expect(storage.snapshot.deviceCheck!.pending, isTrue);
      expect(
        (await controller.startDeviceCheck(deviceCheckSourceAlarm.id)).ok,
        isFalse,
      );
      expect(gateway.testCalls, isEmpty);
      expect((await controller.cancelDeviceCheck()).ok, isTrue);
      expect(gateway.cancelTestCalls, ['preview:recovered']);
    },
  );

  test('recovered native test can be cancelled without overwriting corrupt storage', () async {
    storage.failLoad = true;
    gateway.activeTest = DeviceAlarmCheck(
      sourceAlarmId: deviceCheckSourceAlarm.id,
      previewAlarmId: 'preview:recovered',
      startedAt: gateway.currentTime,
      dueAt: gateway.currentTime.add(const Duration(seconds: 20)),
    );
    await controller.initialize(startPolling: false);
    expect(controller.storageHealthy, isFalse);
    expect(controller.deviceCheck!.pending, isTrue);
    final result = await controller.cancelDeviceCheck();
    expect(gateway.cancelTestCalls, ['preview:recovered']);
    expect(controller.deviceCheck, isNull);
    expect(result.error, contains('отменён'));
    expect(storage.saves, 0);
    expect(storage.snapshot.alarms, [deviceCheckSourceAlarm]);
  });

  test(
    'native rejection never records a successful or pending check',
    () async {
      await controller.initialize(startPolling: false);
      gateway.rejectTest = true;

      final result = await controller.startDeviceCheck(
        deviceCheckSourceAlarm.id,
      );

      expect(result.ok, isFalse);
      expect(result.error, contains('запрещена'));
      expect(controller.deviceCheck, isNull);
      expect(storage.snapshot.deviceCheck, isNull);
      expect(gateway.cancelCalls, isEmpty);
    },
  );

  test(
    'delivery check uses a separate 20-second native alarm and persists it',
    () async {
      await controller.initialize(startPolling: false);

      final result = await controller.startDeviceCheck(
        deviceCheckSourceAlarm.id,
      );

      expect(result.ok, isTrue);
      expect(gateway.testCalls.single, (
        id: deviceCheckSourceAlarm.id,
        delaySeconds: 20,
      ));
      final pending = controller.deviceCheck!;
      expect(pending.sourceAlarmId, deviceCheckSourceAlarm.id);
      expect(pending.previewAlarmId, 'preview:device-check-1');
      expect(
        pending.dueAt,
        gateway.currentTime.add(const Duration(seconds: 20)),
      );
      expect(pending.pending, isTrue);
      expect(pending.heard, isNull);
      expect(pending.confirmedAt, isNull);
      expect(
        storage.snapshot.deviceCheck!.previewAlarmId,
        pending.previewAlarmId,
      );
      expect(gateway.scheduleCalls, isEmpty);
      expect(gateway.nativeAlarms[deviceCheckSourceAlarm.id]!.enabled, isTrue);
    },
  );

  test(
    'reopening after the deadline still requires the user to report delivery',
    () async {
      storage.snapshot = AlarmSnapshot(
        alarms: const [deviceCheckSourceAlarm],
        deviceCheck: DeviceAlarmCheck(
          sourceAlarmId: deviceCheckSourceAlarm.id,
          previewAlarmId: 'preview:earlier-check',
          startedAt: gateway.currentTime.subtract(const Duration(minutes: 2)),
          dueAt: gateway.currentTime.subtract(const Duration(seconds: 100)),
        ),
      );

      await controller.initialize(startPolling: false);
      await controller.refreshStatus();

      expect(controller.deviceCheck!.pending, isTrue);
      expect(controller.deviceCheck!.heard, isNull);
      expect(gateway.testCalls, isEmpty);
      expect(gateway.cancelTestCalls, isEmpty);

      expect((await controller.finishDeviceCheck(heard: false)).ok, isTrue);
      expect(controller.deviceCheck!.heard, isFalse);
      expect(controller.deviceCheck!.confirmedAt, gateway.currentTime);
      expect(storage.snapshot.deviceCheck!.heard, isFalse);
      expect(gateway.cancelTestCalls, ['preview:earlier-check']);
    },
  );

  test('a check cannot be confirmed before its scheduled deadline', () async {
    await controller.initialize(startPolling: false);
    await controller.startDeviceCheck(deviceCheckSourceAlarm.id);

    final result = await controller.finishDeviceCheck(heard: true);

    expect(result.ok, isFalse);
    expect(controller.deviceCheck!.pending, isTrue);
    expect(storage.snapshot.deviceCheck!.heard, isNull);
    expect(gateway.cancelTestCalls, isEmpty);
  });

  test(
    'cancelling a check never cancels or disables the real schedule',
    () async {
      await controller.initialize(startPolling: false);
      await controller.startDeviceCheck(deviceCheckSourceAlarm.id);

      final result = await controller.cancelDeviceCheck();

      expect(result.ok, isTrue);
      expect(controller.deviceCheck, isNull);
      expect(storage.snapshot.deviceCheck, isNull);
      expect(gateway.cancelTestCalls, ['preview:device-check-1']);
      expect(gateway.cancelCalls, isEmpty);
      expect(gateway.dismissCalls, isEmpty);
      expect(gateway.nativeAlarms[deviceCheckSourceAlarm.id]!.enabled, isTrue);
      expect(controller.alarms.single.enabled, isTrue);
    },
  );

  test('failed native cancellation leaves the pending check visible', () async {
    await controller.initialize(startPolling: false);
    await controller.startDeviceCheck(deviceCheckSourceAlarm.id);
    gateway.rejectCancelTest = true;

    final result = await controller.cancelDeviceCheck();

    expect(result.ok, isFalse);
    expect(controller.deviceCheck!.pending, isTrue);
    expect(storage.snapshot.deviceCheck!.pending, isTrue);
    expect(gateway.cancelCalls, isEmpty);
  });

  test(
    'failed initial persistence cancels the new preview and reports failure',
    () async {
      await controller.initialize(startPolling: false);
      storage.failSave = true;

      final result = await controller.startDeviceCheck(
        deviceCheckSourceAlarm.id,
      );

      expect(result.ok, isFalse);
      expect(result.error, isNotEmpty);
      expect(controller.deviceCheck, isNull);
      expect(storage.snapshot.deviceCheck, isNull);
      expect(gateway.cancelTestCalls, ['preview:device-check-1']);
      expect(gateway.cancelCalls, isEmpty);
    },
  );

  test('an unconfirmed rollback stays visible if storage and cancellation both fail', () async {
    await controller.initialize(startPolling: false);
    storage.failSave = true;
    gateway.rejectCancelTest = true;

    final result = await controller.startDeviceCheck(deviceCheckSourceAlarm.id);

    expect(result.ok, isFalse);
    expect(controller.deviceCheck!.pending, isTrue);
    expect(controller.deviceCheck!.heard, isNull);
    expect(storage.snapshot.deviceCheck, isNull);
    expect(gateway.cancelCalls, isEmpty);
  });

  test(
    'failed feedback persistence cannot display a confirmed success',
    () async {
      await controller.initialize(startPolling: false);
      await controller.startDeviceCheck(deviceCheckSourceAlarm.id);
      gateway.currentTime = gateway.currentTime.add(
        const Duration(seconds: 21),
      );
      storage.failSave = true;

      final result = await controller.finishDeviceCheck(heard: true);

      expect(result.ok, isFalse);
      expect(controller.deviceCheck!.pending, isTrue);
      expect(controller.deviceCheck!.heard, isNull);
      expect(storage.snapshot.deviceCheck!.heard, isNull);
      expect(gateway.cancelTestCalls, ['preview:device-check-1']);
      expect(gateway.cancelCalls, isEmpty);
    },
  );

  test('a stale result screen cannot finish a newer check', () async {
    await controller.initialize(startPolling: false);
    await controller.startDeviceCheck(deviceCheckSourceAlarm.id);
    final oldId = controller.deviceCheck!.previewAlarmId;
    await controller.cancelDeviceCheck();
    await controller.startDeviceCheck(deviceCheckSourceAlarm.id);
    gateway.currentTime = gateway.currentTime.add(const Duration(seconds: 21));

    final result = await controller.finishDeviceCheck(
      heard: true,
      previewAlarmId: oldId,
    );

    expect(result.ok, isFalse);
    expect(controller.deviceCheck!.previewAlarmId, 'preview:device-check-2');
    expect(controller.deviceCheck!.pending, isTrue);
    expect(gateway.cancelTestCalls, [oldId]);
  });

  test('browser preview cannot schedule a device delivery check', () async {
    gateway.supported = false;
    await controller.initialize(startPolling: false);

    final result = await controller.startDeviceCheck(deviceCheckSourceAlarm.id);

    expect(result.ok, isFalse);
    expect(controller.deviceCheck, isNull);
    expect(gateway.testCalls, isEmpty);
  });

  test(
    'v0.1 local state remains readable without inventing a device check',
    () async {
      await LocalDatabase.instance.close();
      LocalDatabase.instance = LocalDatabase(path: ':memory:');
      SharedPreferences.setMockInitialValues({
        'five_more.state.v1': jsonEncode({
          'version': 1,
          'alarms': [deviceCheckSourceAlarm.toJson()],
          'events': <Object>[],
        }),
      });
      final localStorage = LocalAlarmStorage();

      final snapshot = await localStorage.load();
      expect(snapshot.alarms.single.id, deviceCheckSourceAlarm.id);
      expect(snapshot.alarms.single.enabled, isTrue);
      expect(snapshot.deviceCheck, isNull);

      await localStorage.save(snapshot);
      final reopened = await localStorage.load();
      expect(reopened.alarms.single.id, deviceCheckSourceAlarm.id);
      expect(reopened.deviceCheck, isNull);
    },
  );

  test('persisted feedback survives a real storage round trip', () async {
    await LocalDatabase.instance.close();
    LocalDatabase.instance = LocalDatabase(path: ':memory:');
    SharedPreferences.setMockInitialValues({});
    final localStorage = LocalAlarmStorage();
    final pending = DeviceAlarmCheck(
      sourceAlarmId: deviceCheckSourceAlarm.id,
      previewAlarmId: 'preview:stored-check',
      startedAt: gateway.currentTime,
      dueAt: gateway.currentTime.add(const Duration(seconds: 20)),
    );
    await localStorage.save(
      AlarmSnapshot(
        alarms: const [deviceCheckSourceAlarm],
        deviceCheck: pending,
      ),
    );

    final restored = (await localStorage.load()).deviceCheck!;
    expect(restored.previewAlarmId, pending.previewAlarmId);
    expect(restored.dueAt, pending.dueAt);
    expect(restored.pending, isTrue);
    expect(restored.confirmedAt, isNull);

    final confirmed = restored.confirmed(
      heard: true,
      at: gateway.currentTime.add(const Duration(seconds: 22)),
    );
    await localStorage.save(
      AlarmSnapshot(
        alarms: const [deviceCheckSourceAlarm],
        deviceCheck: confirmed,
      ),
    );
    final completed = (await localStorage.load()).deviceCheck!;
    expect(completed.heard, isTrue);
    expect(completed.confirmedAt, confirmed.confirmedAt);
    expect(completed.pending, isFalse);
  });

  test(
    'a corrupt optional check cannot hide the existing alarm list',
    () async {
      await LocalDatabase.instance.close();
      LocalDatabase.instance = LocalDatabase(path: ':memory:');
      SharedPreferences.setMockInitialValues({
        'five_more.state.v1': jsonEncode({
          'version': 2,
          'alarms': [deviceCheckSourceAlarm.toJson()],
          'events': <Object>[],
          'deviceCheck': {
            'sourceAlarmId': deviceCheckSourceAlarm.id,
            'previewAlarmId': 'preview:corrupt-check',
            'startedAt': 9223372036854775807,
            'dueAt': gateway.currentTime.millisecondsSinceEpoch,
          },
        }),
      });

      final restored = await LocalAlarmStorage().load();

      expect(restored.alarms.single.id, deviceCheckSourceAlarm.id);
      expect(restored.deviceCheck, isNull);
    },
  );
}
