import 'dart:convert';

import 'package:five_more/features/challenges/challenge_models.dart';
import 'package:five_more/features/challenges/challenge_screen.dart';
import 'package:five_more/app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ui_helpers.dart';

void main() {
  test('saved mixed order and exact one-stage penalty survive restoration', () {
    final session = ChallengeSession(
      kind: ChallengeKind.mixed,
      difficulty: ChallengeDifficulty.hard,
      order: [ChallengeKind.math, ChallengeKind.memory, ChallengeKind.sequence],
    );
    session.submitCorrect();
    session.submitCorrect();
    final restored = ChallengeSession.restore(
      session.toJson(),
      session.kind,
      session.difficulty,
    )!;
    expect(restored.currentKind, ChallengeKind.sequence);
    restored.submitIncorrect();
    expect(restored.completedSteps, 1);
    expect(restored.currentKind, ChallengeKind.memory);
    expect(
      ChallengeSession.restore(
        session.toJson(),
        session.kind,
        ChallengeDifficulty.extreme,
      ),
      isNull,
    );
  });
  testWidgets(
    'reopening a ring continues saved stages and completes normally',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final progress = ChallengeSession(
        kind: ChallengeKind.math,
        difficulty: ChallengeDifficulty.easy,
      )..submitCorrect();
      await prefs.setString(
        'five_more.challenge.v1',
        jsonEncode({'identity': 'occurrence:0', 'session': progress.toJson()}),
      );
      var completed = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: fiveMoreTheme(),
          home: ChallengeScreen(
            kind: ChallengeKind.math,
            difficulty: ChallengeDifficulty.easy,
            progressIdentity: 'occurrence:0',
            onComplete: () => completed++,
            onEmergencyExit: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);
      final expression = tester
          .widget<Text>(
            find.byWidgetPredicate(
              (w) =>
                  w is Text && RegExp(r'^\d+ [ +−] \d+').hasMatch(w.data ?? ''),
            ),
          )
          .data!;
      await tester.tap(
        find.widgetWithText(FilledButton, '${evaluateMath(expression)}'),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      expect(completed, 1);
      final checkpoint =
          jsonDecode(prefs.getString('five_more.challenge.v1')!) as Map;
      expect(checkpoint['session']['completedSteps'], 2);
    },
  );
}
