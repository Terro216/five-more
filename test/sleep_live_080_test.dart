import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/app/theme.dart';
import 'package:five_more/features/sleep/sleep_review.dart';
import 'package:five_more/models/alarm.dart';
import 'package:five_more/models/sleep_session.dart';
import 'package:five_more/services/alarm_storage.dart';
import 'package:five_more/services/sleep_journal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'alarm_fakes.dart';

AlarmEvent end(String id, DateTime at) => AlarmEvent(
  eventId: id,
  alarmId: id,
  occurrenceId: id,
  type: 'dismissed',
  at: at,
);

void main() {
  test(
    'sleep interval query keeps setup outside the latest 500 events',
    () async {
      final storage = LocalAlarmStorage();
      final now = DateTime(2026, 11, 10, 7);
      final bedtime = now.subtract(const Duration(hours: 8));
      await storage.save(
        AlarmSnapshot(
          events: [
            AlarmEvent(
              eventId: 'setup',
              alarmId: 'a',
              occurrenceId: 'setup',
              type: 'armed',
              at: bedtime,
              nextAt: now,
            ),
            for (var i = 0; i < 550; i++)
              AlarmEvent(
                eventId: 'noise$i',
                alarmId: 'noise',
                occurrenceId: 'p$i',
                type: 'snoozed',
                at: now.subtract(Duration(seconds: 600 - i)),
              ),
            AlarmEvent(
              eventId: 'final',
              alarmId: 'a',
              occurrenceId: 'wake',
              type: 'dismissed',
              at: now,
            ),
          ],
        ),
      );
      expect((await storage.load()).events, hasLength(500));
      final events = await storage.eventsBetween(
        bedtime.subtract(const Duration(hours: 1)),
        now.add(const Duration(minutes: 1)),
      );
      expect(events, hasLength(552));
      expect(SleepSession.fromEvents(events).single.bedtimeCandidate, bedtime);
    },
  );

  testWidgets(
    'open proposal follows a later completion and preserves confirmed times',
    (tester) async {
      final now = DateTime(2026, 11, 10, 7);
      final first = end('one', now);
      final gateway = FakeAlarmGateway();
      final storage = MemoryAlarmStorage()
        ..snapshot = AlarmSnapshot(events: [first]);
      final controller = AlarmController(
        gateway: gateway,
        storage: storage,
        now: () => now.add(const Duration(hours: 1)),
      );
      await controller.initialize(startPolling: false);
      addTearDown(controller.dispose);
      final journal = SleepJournal()..ready = true;
      addTearDown(journal.dispose);
      Future<void> mount(AlarmEvent event, SleepSession session) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: fiveMoreTheme(),
            home: SleepReview(
              journal: journal,
              event: event,
              session: session,
              controller: controller,
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await mount(first, SleepSession.fromEvents([first]).single);
      expect(find.text('07:00'), findsOneWidget);
      gateway.pendingEvents.add(
        end('two', now.add(const Duration(minutes: 30))),
      );
      await controller.poll();
      await tester.pumpAndSettle();
      expect(find.text('07:30'), findsOneWidget);
      final save = find.text('Сохранить оценку');
      await tester.scrollUntilVisible(
        save,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(save);
      await tester.tap(save);
      for (var i = 0; i < 50 && journal.entries.isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(
        journal.entries.single.wokeAt,
        now.add(const Duration(minutes: 30)),
      );
      expect(journal.entries.single.occurrences, ['one', 'two']);
      await tester.pumpWidget(const SizedBox.shrink());
      await mount(
        first,
        SleepSession.fromEvents(controller.sleepEvents).single,
      );
      gateway.pendingEvents.add(
        end('three', now.add(const Duration(minutes: 50))),
      );
      await controller.poll();
      await tester.pumpAndSettle();
      expect(find.text('07:30'), findsOneWidget);
      expect(find.text('07:50'), findsNothing);
    },
  );
  testWidgets('a later alarm keeps manually edited wake time', (tester) async {
    final now = DateTime(2026, 11, 10, 7);
    final first = end('one', now);
    final gateway = FakeAlarmGateway();
    final controller = AlarmController(
      gateway: gateway,
      storage: MemoryAlarmStorage()..snapshot = AlarmSnapshot(events: [first]),
      now: () => now.add(const Duration(hours: 1)),
    );
    await controller.initialize(startPolling: false);
    addTearDown(controller.dispose);
    final journal = SleepJournal()..ready = true;
    addTearDown(journal.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: fiveMoreTheme(),
        home: SleepReview(
          journal: journal,
          event: first,
          session: SleepSession.fromEvents([first]).single,
          controller: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Время подъёма'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Время подъёма'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('time-minute-input')),
      '12',
    );
    await tester.tap(find.text('Готово'));
    await tester.pumpAndSettle();
    gateway.pendingEvents.add(end('two', now.add(const Duration(minutes: 30))));
    await controller.poll();
    await tester.pumpAndSettle();
    expect(find.text('07:12'), findsOneWidget);
    expect(find.text('07:30'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
