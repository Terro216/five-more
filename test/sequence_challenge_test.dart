import 'ui_helpers.dart';

import 'dart:math';

import 'package:five_more/app/theme.dart';
import 'package:five_more/features/challenges/challenge_models.dart';
import 'package:five_more/features/challenges/challenge_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sequence boards are immutable shuffled permutations at each level', () {
    for (final difficulty in ChallengeDifficulty.values) {
      final expectedCount = [6, 9, 16, 25][difficulty.index];
      for (var seed = 0; seed < 100; seed += 1) {
        final board = generateSequenceBoard(Random(seed), difficulty);
        expect(board.columns, difficulty.index >= 2 ? difficulty.index + 2 : 3);
        expect(board.cellCount, expectedCount);
        expect(board.numbers.toSet(), {
          for (var number = 1; number <= expectedCount; number += 1) number,
        });
        expect(
          board.numbers,
          isNot(
            orderedEquals(List.generate(expectedCount, (index) => index + 1)),
          ),
        );
        expect(() => board.numbers[0] = 0, throwsUnsupportedError);
        for (var completed = 0; completed < expectedCount; completed += 1) {
          expect(
            board.numbers.where(
              (number) => board.accepts(number, completedCount: completed),
            ),
            [completed + 1],
          );
        }
        expect(board.accepts(1, completedCount: -1), isFalse);
        expect(
          board.accepts(expectedCount + 1, completedCount: expectedCount),
          isFalse,
        );
      }
    }
  });

  test('sequence sessions have a bounded number of boards at each level', () {
    for (final difficulty in ChallengeDifficulty.values) {
      final session = ChallengeSession(
        kind: ChallengeKind.sequence,
        difficulty: difficulty,
      );
      expect(
        session.totalSteps,
        difficulty.index >= 2 ? difficulty.index + 1 : 2,
      );
      expect(
        session.rounds.every((kind) => kind == ChallengeKind.sequence),
        isTrue,
      );
    }
  });

  Future<void> showSequence(
    WidgetTester tester, {
    ChallengeDifficulty difficulty = ChallengeDifficulty.easy,
    VoidCallback? onComplete,
    VoidCallback? onEmergencyExit,
    double width = 390,
    double height = 844,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: fiveMoreTheme(),
        locale: const Locale('ru'),
        supportedLocales: const [Locale('ru'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: ChallengeScreen(
          kind: ChallengeKind.sequence,
          difficulty: difficulty,
          practice: onEmergencyExit == null,
          onComplete: onComplete ?? () {},
          onEmergencyExit: onEmergencyExit,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder number(int value) => find.byKey(ValueKey('sequence-number-$value'));

  Future<void> tapNumber(WidgetTester tester, int value) async {
    await tester.ensureVisible(number(value));
    await tester.pumpAndSettle();
    await tester.tap(number(value));
    await tester.pump();
  }

  testWidgets(
    'wrong numbers reset the current board; repeated taps do not advance',
    (tester) async {
      var completions = 0;
      await showSequence(tester, onComplete: () => completions += 1);
      await tapNumber(tester, 3);
      expect(find.text('Следующее: 1'), findsOneWidget);
      expect(find.text('1 / 2'), findsOneWidget);
      await tapNumber(tester, 1);
      expect(find.text('Следующее: 2'), findsOneWidget);
      final first = tester.widget<Semantics>(number(1));
      expect(first.properties.label, 'Число 1');
      expect(first.properties.selected, isTrue);
      expect(first.properties.enabled, isFalse);
      await tapNumber(tester, 1);
      await tapNumber(tester, 4);
      expect(find.text('Следующее: 1'), findsOneWidget);
      expect(tester.widget<Semantics>(number(1)).properties.selected, isFalse);
      await tapNumber(tester, 1);
      await tapNumber(tester, 2);
      expect(find.text('Следующее: 3'), findsOneWidget);
      expect(completions, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('all numbers advance boards and rapid last taps complete once', (
    tester,
  ) async {
    var completions = 0;
    await showSequence(tester, onComplete: () => completions += 1);
    for (var board = 0; board < 2; board += 1) {
      expect(find.text('${board + 1} / 2'), findsOneWidget);
      for (var value = 1; value < 6; value += 1) {
        await tapNumber(tester, value);
      }
      await tester.ensureVisible(number(6));
      await tester.pumpAndSettle();
      await tester.tap(number(6));
      // A second pointer event can arrive before the first frame disables it.
      await tester.tap(number(6));
      await tester.pump();
      expect(find.text('Все числа найдены'), findsOneWidget);
      expect(completions, 0);
      await tester.pump(const Duration(milliseconds: 500));
      if (board == 0) {
        expect(find.text('Следующее: 1'), findsOneWidget);
        expect(
          tester.widget<Semantics>(number(1)).properties.selected,
          isFalse,
        );
      }
    }
    expect(completions, 1);
    await tester.pump(const Duration(seconds: 2));
    expect(completions, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'hard grid keeps 48px targets and emergency visible at large text',
    (tester) async {
      var exits = 0;
      await showSequence(
        tester,
        difficulty: ChallengeDifficulty.hard,
        width: 320,
        height: 640,
        textScale: 1.6,
        onEmergencyExit: () => exits += 1,
      );
      for (var value = 1; value <= 12; value += 1) {
        final size = tester.getSize(number(value));
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
      }
      final emergency = find.text('Не получается пройти');
      expect(emergency.hitTestable(), findsOneWidget);
      expect(tester.getBottomRight(emergency).dy, lessThanOrEqualTo(640));
      await tester.tap(emergency);
      await tester.pumpAndSettle();
      expect(exits, 0);
      await completeEmergencyHold(tester);
      await tester.pumpAndSettle();
      expect(exits, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('emergency during final transition cancels delayed completion', (
    tester,
  ) async {
    var completions = 0;
    var exits = 0;
    await showSequence(
      tester,
      onComplete: () => completions += 1,
      onEmergencyExit: () => exits += 1,
    );
    for (var board = 0; board < 2; board += 1) {
      for (var value = 1; value <= 6; value += 1) {
        await tapNumber(tester, value);
      }
      if (board == 0) await tester.pump(const Duration(milliseconds: 500));
    }
    await tester.tap(find.text('Не получается пройти'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    expect(completions, 0);
    await completeEmergencyHold(tester);
    await tester.pumpAndSettle();
    expect(exits, 1);
    expect(completions, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'declining emergency delivers a completed sequence exactly once',
    (tester) async {
      var completions = 0;
      var exits = 0;
      await showSequence(
        tester,
        onComplete: () => completions += 1,
        onEmergencyExit: () => exits += 1,
      );
      for (var board = 0; board < 2; board += 1) {
        for (var value = 1; value <= 6; value += 1) {
          await tapNumber(tester, value);
        }
        if (board == 0) await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.tap(find.text('Не получается пройти'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      expect(completions, 0);
      await tester.tap(find.text('Вернуться к заданию'));
      await tester.pumpAndSettle();
      expect(exits, 0);
      expect(completions, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(completions, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
