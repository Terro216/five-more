import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/models/alarm.dart';
import 'package:five_more/services/alarm_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'alarm_fakes.dart';

const oneShot = Alarm(
  id: 'one',
  hour: 7,
  minute: 30,
  configurationId: 'v1',
  deleteAfterDismiss: true,
);
AlarmEvent event(String type, {String revision = 'v1'}) => AlarmEvent(
  eventId: 'event',
  alarmId: 'one',
  occurrenceId: 'occurrence',
  configurationId: revision,
  type: type,
  at: DateTime(2026, 11, 10, 7, 30),
);

void main() {
  for (final type in [
    'dismissed',
    'emergency_dismissed',
    'snoozed',
    'fired',
    'timed_out',
    'missed',
    'schedule_failed',
  ]) {
    test(
      'one-shot cleanup responds only to final user dismissal: $type',
      () async {
        final finalEvent = ['dismissed', 'emergency_dismissed'].contains(type);
        final storage = MemoryAlarmStorage()
          ..snapshot = const AlarmSnapshot(alarms: [oneShot]);
        final gateway = FakeAlarmGateway()..pendingEvents.add(event(type));
        gateway.beforeAck = (_) {
          expect(storage.snapshot.events.single.type, type);
          expect(storage.snapshot.alarms.isEmpty, finalEvent);
        };
        final controller = AlarmController(gateway: gateway, storage: storage);
        addTearDown(controller.dispose);
        await controller.initialize(startPolling: false);
        expect(controller.alarms.isEmpty, finalEvent);
        expect(storage.snapshot.events.single.occurrenceId, 'occurrence');
      },
    );
  }
  test('history failure leaves native events pending; replay cleans up after durable retry', () async {
    final storage = MemoryAlarmStorage()
      ..snapshot = const AlarmSnapshot(alarms: [oneShot])
      ..failSave = true;
    final gateway = FakeAlarmGateway()..pendingEvents.add(event('dismissed'));
    final controller = AlarmController(gateway: gateway, storage: storage);
    addTearDown(controller.dispose);
    await controller.initialize(startPolling: false);
    expect(controller.alarms, hasLength(1));
    expect(gateway.acknowledged, isEmpty);
    storage.failSave = false;
    await controller.poll();
    expect(controller.alarms, isEmpty);
    expect(storage.snapshot.events, hasLength(1));
    expect(gateway.acknowledged, ['event']);
    gateway.pendingEvents.add(event('dismissed'));
    await controller.poll();
    expect(storage.snapshot.events, hasLength(1));
    final restarted = AlarmController(gateway: gateway, storage: storage);
    addTearDown(restarted.dispose);
    await restarted.initialize(startPolling: false);
    expect(restarted.alarms, isEmpty);
    expect(restarted.events, hasLength(1));
  });
  test('late dismissal does not disable or delete a reconfigured ID', () async {
    final replacement = oneShot.copyWith(configurationId: 'v2', hour: 9);
    final storage = MemoryAlarmStorage()
      ..snapshot = AlarmSnapshot(alarms: [replacement]);
    final gateway = FakeAlarmGateway()..pendingEvents.add(event('dismissed'));
    final controller = AlarmController(gateway: gateway, storage: storage);
    addTearDown(controller.dispose);
    await controller.initialize(startPolling: false);
    expect(controller.alarms.single.enabled, isTrue);
    expect(controller.alarms.single.hour, 9);
    expect(storage.snapshot.events, hasLength(1));
    // Transport-only identity is not added to the 0.7 server history contract.
    expect(
      storage.snapshot.events.single.toJson().containsKey('configurationId'),
      isFalse,
    );
  });
}
