import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/app/theme.dart';
import 'package:five_more/features/alarms/alarm_home.dart';
import 'package:five_more/features/challenges/challenge_models.dart';
import 'package:five_more/features/challenges/challenge_screen.dart';
import 'package:five_more/features/challenges/physical_tasks.dart';
import 'package:five_more/features/sleep/sleep_review.dart';
import 'package:five_more/models/alarm.dart';
import 'package:five_more/models/sleep_entry.dart';
import 'package:five_more/models/sleep_session.dart';
import 'package:five_more/services/alarm_storage.dart';
import 'package:five_more/services/sleep_journal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'alarm_fakes.dart';

AlarmEvent event(
  String id,
  DateTime at, {
  String type = 'dismissed',
  DateTime? next,
}) => AlarmEvent(
  eventId: '$id:$type',
  alarmId: 'alarm',
  occurrenceId: id,
  type: type,
  at: at,
  nextAt: next,
);

void main() {
  test('morning setup does not replace last night with a one hour sleep', () {
    final wake = DateTime(2026, 11, 16, 10);
    final session = SleepSession.fromEvents([
      event('set', DateTime(2026, 11, 16, 9), type: 'armed', next: wake),
      event('morning', wake),
    ]).single;
    expect(session.bedtimeCandidate, isNull);
  });

  test('extreme shake needs sustained movements rather than a short burst', () {
    final counter = ShakeCounter.forDifficulty(ChallengeDifficulty.extreme);
    for (var i = 0; i < 240; i++) {
      expect(
        counter.add(i.isEven ? 14 : -14, 0, 0, Duration(milliseconds: i * 160)),
        isFalse,
      );
    }
    expect(counter.count, lessThan(counter.target));
    var completed = false;
    for (var i = 240; i < 260; i++) {
      completed = counter.add(
        i.isEven ? 14 : -14,
        0,
        0,
        Duration(milliseconds: i * 160),
      );
      if (completed) break;
    }
    expect(completed, isTrue);
    final easy = ShakeCounter.forDifficulty(ChallengeDifficulty.easy);
    expect(counter.target, greaterThan(easy.target * 5));
  });

  test(
    'sleep comments survive SQLite reload and stay outside sync records',
    () async {
      final journal = SleepJournal();
      await journal.load();
      addTearDown(journal.dispose);
      final morning = DateTime(2026, 11, 16, 9);
      await journal.saveEntry(
        SleepEntry(
          occurrenceId: 'night',
          wokeAt: morning,
          bedAt: morning.subtract(const Duration(hours: 8)),
          sleepQuality: 4,
          wakeQuality: 3,
        ),
        comment: 'Окно было открыто',
      );
      final restored = SleepJournal();
      await restored.load();
      addTearDown(restored.dispose);
      expect(restored.comments['night'], 'Окно было открыто');
      expect(restored.entries.single.toJson().containsKey('comment'), isFalse);
      await restored.skipAll(['one', 'two']);
      expect(restored.reported('one'), isTrue);
      expect(restored.reported('two'), isTrue);
    },
  );

  testWidgets('memory training keeps a wrong answer visible for review', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: fiveMoreTheme(),
        home: ChallengeScreen(
          kind: ChallengeKind.memory,
          difficulty: ChallengeDifficulty.hard,
          practice: true,
          onComplete: () {},
        ),
      ),
    );
    final cells = tester
        .widgetList<Semantics>(
          find.descendant(
            of: find.byKey(const ValueKey('complete-memory-preview')),
            matching: find.byType(Semantics),
          ),
        )
        .where((w) => w.properties.label?.startsWith('Ряд ') ?? false)
        .toList();
    final marked = cells.where((w) => w.properties.selected == true).toList();
    final unmarked = cells.firstWhere((w) => w.properties.selected != true);
    final answers = [unmarked, ...marked.skip(1)];
    await tester.tap(find.text('Запомнил, начнём'));
    await tester.pump();
    for (final cell in answers) {
      final target = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == cell.properties.label,
      );
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pump();
    }
    await tester.ensureVisible(find.text('Проверить'));
    await tester.tap(find.text('Проверить'));
    await tester.pump();
    expect(
      find.text('Есть ошибки. Сравни свой ответ с рисунком.'),
      findsOneWidget,
    );
    expect(find.text('Разберём рисунок'), findsOneWidget);
    expect(
      find.byIcon(Icons.close),
      findsNWidgets(2),
    ); // Close training and one wrong cell.
    expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);
    await tester.ensureVisible(find.text('Попробовать ещё раз'));
    await tester.tap(find.text('Попробовать ещё раз'));
    await tester.pump();
    expect(find.text('Запомни рисунок'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'saving latest morning does not expose a queue of older prompts',
    (tester) async {
      final now = DateTime(2026, 11, 16, 11);
      final controller = AlarmController(
        gateway: FakeAlarmGateway(),
        storage: MemoryAlarmStorage()
          ..snapshot = AlarmSnapshot(
            events: [
              event('early', DateTime(2026, 11, 16, 6)),
              event('late', DateTime(2026, 11, 16, 10)),
            ],
          ),
        now: () => now,
      );
      await controller.initialize(startPolling: false);
      addTearDown(controller.dispose);
      final journal = SleepJournal();
      await tester.runAsync(() async {
        await journal.load();
        await journal.skip('late');
      });
      journal.dispose();
      await tester.pumpWidget(
        MaterialApp(
          theme: fiveMoreTheme(),
          home: AlarmHome(controller: controller),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Оценить утро'), findsNothing);
      expect(find.text('Дневник сна'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'morning review identifies its date and separates rating meanings',
    (tester) async {
      final journal = SleepJournal()..ready = true;
      addTearDown(journal.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: fiveMoreTheme(),
          home: SleepReview(
            journal: journal,
            event: event('morning', DateTime(2026, 11, 16, 10)),
          ),
        ),
      );
      expect(find.text('Сон к 16.11.2026'), findsOneWidget);
      expect(find.text('1 — плохо · 5 — хорошо'), findsOneWidget);
      expect(find.text('1 — с трудом · 5 — легко'), findsOneWidget);
    },
  );
}
