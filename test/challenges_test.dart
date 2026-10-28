import 'ui_helpers.dart';

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:five_more/features/challenges/challenge_models.dart';
import 'package:five_more/features/challenges/challenge_screen.dart';

void main() {
  group('Math questions', () {
    test('each generated question has exactly one correct choice', () {
      for (final difficulty in ChallengeDifficulty.values) {
        for (var seed = 0; seed < 200; seed += 1) {
          final question = generateMathQuestion(
            Random(seed),
            difficulty,
            round: seed % 5,
          );
          expect(question.choices, hasLength(4));
          expect(question.choices.toSet(), hasLength(4));
          expect(question.choices.where(question.accepts), [question.answer]);
          expect(question.answer, _calculateExpression(question.expression));
        }
      }
    });
  });

  group('Memory patterns', () {
    test('patterns contain unique, valid cells and reject partial guesses', () {
      for (final difficulty in ChallengeDifficulty.values) {
        for (var seed = 0; seed < 100; seed += 1) {
          final pattern = generateMemoryPattern(Random(seed), difficulty);
          expect(pattern.cells.length, lessThan(pattern.cellCount));
          expect(
            pattern.cells.every(
              (cell) => cell >= 0 && cell < pattern.cellCount,
            ),
            isTrue,
          );
          expect(pattern.accepts({...pattern.cells}), isTrue);
          expect(pattern.accepts({}), isFalse);
          final incomplete = {...pattern.cells}..remove(pattern.cells.first);
          expect(pattern.accepts(incomplete), isFalse);
          final extra = List.generate(
            pattern.cellCount,
            (i) => i,
          ).firstWhere((cell) => !pattern.cells.contains(cell));
          expect(pattern.accepts({...pattern.cells, extra}), isFalse);
        }
      }
    });
  });

  group('Stroop questions', () {
    test('word and ink differ and only the ink is accepted', () {
      for (final difficulty in ChallengeDifficulty.values) {
        for (var seed = 0; seed < 100; seed += 1) {
          final question = generateStroopQuestion(Random(seed), difficulty);
          expect(question.ink, isNot(question.word));
          expect(question.choices.toSet().length, question.choices.length);
          expect(question.choices.where(question.accepts), [question.ink]);
          expect(question.accepts(question.word), isFalse);
        }
      }
    });
  });

  group('Challenge progression', () {
    test('mistakes return one step and never prevent completion', () {
      final session = ChallengeSession(
        kind: ChallengeKind.math,
        difficulty: ChallengeDifficulty.medium,
      );
      expect(session.submitCorrect(), isFalse);
      for (var attempt = 0; attempt < 100; attempt += 1) {
        session.submitIncorrect();
      }
      expect(session.completedSteps, 0);
      expect(session.mistakes, 100);
      while (!session.isComplete) {
        session.submitCorrect();
      }
      expect(session.progress, 1);
      expect(session.submitCorrect(), isFalse);
      session.submitIncorrect();
      expect(session.mistakes, 100);
    });

    test('mixed mode includes every concrete task exactly once', () {
      final session = ChallengeSession(
        kind: ChallengeKind.mixed,
        difficulty: ChallengeDifficulty.hard,
        random: Random(12),
      );
      expect(session.rounds.toSet(), {
        ChallengeKind.math,
        ChallengeKind.memory,
        ChallengeKind.stroop,
        ChallengeKind.sequence,
        ChallengeKind.mirror,
        ChallengeKind.captcha,
        ChallengeKind.flags,
      });
      expect(session.rounds, hasLength(7));
    });
  });

  testWidgets('practice math renders answers without stopping a live alarm', (
    tester,
  ) async {
    var completed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: ChallengeScreen(
          kind: ChallengeKind.math,
          difficulty: ChallengeDifficulty.easy,
          practice: true,
          onComplete: () => completed = true,
        ),
      ),
    );
    expect(find.text('Пробный подъём'), findsOneWidget);
    expect(find.byType(FilledButton), findsNWidgets(4));
    expect(find.text('Проблема с заданием'), findsNothing);
    expect(completed, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('emergency exit needs confirmation', (tester) async {
    var exited = false;
    await tester.pumpWidget(
      MaterialApp(
        home: ChallengeScreen(
          kind: ChallengeKind.math,
          difficulty: ChallengeDifficulty.easy,
          onComplete: () {},
          onEmergencyExit: () => exited = true,
        ),
      ),
    );
    await tester.tap(find.text('Проблема с заданием'));
    await tester.pumpAndSettle();
    expect(exited, isFalse);
    expect(find.text('Аварийная остановка'), findsOneWidget);
    await completeEmergencyHold(tester);
    await tester.pumpAndSettle();
    expect(exited, isTrue);
  });

  testWidgets('solving all steps completes exactly once', (tester) async {
    var completions = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChallengeScreen(
          kind: ChallengeKind.math,
          difficulty: ChallengeDifficulty.easy,
          practice: true,
          onComplete: () => completions += 1,
        ),
      ),
    );
    for (var step = 0; step < 2; step += 1) {
      final expression = tester.widget<Text>(
        find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              RegExp(r'^\d+ [ +−×÷] \d+').hasMatch(widget.data ?? ''),
        ),
      );
      final answer = _calculateExpression(expression.data!);
      final choice = find.widgetWithText(FilledButton, '$answer');
      await tester.ensureVisible(choice);
      await tester.tap(choice);
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(completions, 1);
    await tester.pump(const Duration(seconds: 2));
    expect(completions, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('memory preview can be dismissed without waiting', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ChallengeScreen(
          kind: ChallengeKind.memory,
          difficulty: ChallengeDifficulty.hard,
          practice: true,
          onComplete: () {},
        ),
      ),
    );
    expect(find.text('Запомни рисунок'), findsOneWidget);
    await tester.ensureVisible(find.text('Запомнил, начнём'));
    await tester.tap(find.text('Запомнил, начнём'));
    await tester.pump();
    expect(find.text('Повтори рисунок'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

int _calculateExpression(String expression) => evaluateMath(expression);
