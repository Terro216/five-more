import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/models/alarm.dart';
import 'package:five_more/models/snooze_position.dart';
import 'package:flutter_test/flutter_test.dart';

import 'alarm_fakes.dart';

void main() {
  test(
    'legacy count migrates to minutes without changing challenge escalation',
    () {
      final alarm = Alarm.fromJson({
        'id': 'a',
        'hour': 7,
        'minute': 0,
        'maxSnoozes': 3,
        'snoozeMinutes': 5,
      });
      expect(alarm.snoozeBudget, 15);
      expect(alarm.escalateOnSnooze, isFalse);
      expect(Alarm.fromJson(alarm.toJson()).snoozeBudget, 15);
    },
  );

  test(
    '14 short snoozes leave one usable minute and cannot exceed budget',
    () async {
      const alarm = Alarm(id: 'a', hour: 7, minute: 0, snoozeBudgetMinutes: 15);
      final active = RingingAlarm(
        alarm: alarm,
        occurrenceId: 'o',
        firedAt: DateTime(2026),
        snoozesUsed: 14,
        snoozedMinutes: 14,
      );
      final gateway = FakeAlarmGateway()..ringing = active;
      final controller = AlarmController(
        gateway: gateway,
        storage: MemoryAlarmStorage(),
      );
      addTearDown(controller.dispose);
      await controller.initialize(startPolling: false);
      expect(active.minutesRemaining, 1);
      expect(active.defaultSnoozeMinutes, 1);
      expect((await controller.snooze(minutes: 2)).ok, isFalse);
      expect(gateway.snoozeCalls, isEmpty);
      expect((await controller.snooze(minutes: 1)).ok, isTrue);
    },
  );

  test(
    'search target stays stable on rebuild and changes after every snooze',
    () {
      for (var count = 0; count < 300; count++) {
        final tile = snoozeTileFor('occurrence', count);
        expect(tile, inInclusiveRange(0, 5));
        expect(snoozeTileFor('occurrence', count), tile);
        expect(snoozeTileFor('occurrence', count + 1), isNot(tile));
      }
    },
  );
}
