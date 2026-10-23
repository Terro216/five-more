import 'dart:math';

import 'package:five_more/features/challenges/challenge_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'mirror accepts complete readable phrases with normal typing variations',
    () {
      const question = MirrorTextQuestion('Я выбираю ранний подъём');
      expect(question.accepts('  я   ВЫБИРАЮ\nранний подъем  '), isTrue);
      expect(question.accepts(''), isFalse);
      expect(question.accepts('я выбираю ранний'), isFalse);
      expect(question.accepts('я выбираю ранний подьем'), isFalse);
      expect(
        question.accepts(question.text.split('').reversed.join()),
        isFalse,
      );
    },
  );

  test(
    'mirror difficulty increases phrase length and avoids consecutive repeats',
    () {
      for (var seed = 0; seed < 100; seed += 1) {
        final lengths = <int>[];
        for (final difficulty in ChallengeDifficulty.values) {
          final random = Random(seed);
          final first = generateMirrorTextQuestion(random, difficulty);
          final second = generateMirrorTextQuestion(
            random,
            difficulty,
            previous: first.text,
          );
          expect(second.text, isNot(first.text));
          expect(RegExp(r'^[а-яё ]+$').hasMatch(first.text), isTrue);
          expect(first.accepts(first.text), isTrue);
          lengths.add(first.text.length);
        }
        expect(lengths[0], lessThan(lengths[1]));
        expect(lengths[1], lessThan(lengths[2]));
      }
    },
  );

  test(
    'captcha has clear mixed ASCII codes and bounded stable glyph rotations',
    () {
      for (final difficulty in ChallengeDifficulty.values) {
        for (var seed = 0; seed < 200; seed += 1) {
          final random = Random(seed);
          final question = generateCaptchaQuestion(random, difficulty);
          expect(question.code.length, 4 + difficulty.index);
          expect(
            question.code.split('').every(captchaAlphabet.contains),
            isTrue,
          );
          expect(RegExp('[A-Z]').hasMatch(question.code), isTrue);
          expect(RegExp('[0-9]').hasMatch(question.code), isTrue);
          expect(RegExp('[O0IL1B8S5Z2DQG]').hasMatch(question.code), isFalse);
          expect(question.rotations, hasLength(question.code.length));
          expect(
            question.rotations.every((value) => value.abs() <= .15),
            isTrue,
          );
          expect(() => question.rotations[0] = 1, throwsUnsupportedError);
          expect(
            question.accepts('  ${question.code.toLowerCase()}  '),
            isTrue,
          );
          expect(question.accepts(question.code.substring(1)), isFalse);
          expect(question.accepts('${question.code}A'), isFalse);
          expect(question.accepts(question.code.split('').join(' ')), isFalse);
          expect(
            generateCaptchaQuestion(
              random,
              difficulty,
              previous: question.code,
            ).code,
            isNot(question.code),
          );
        }
      }
    },
  );

  test(
    'typed tasks have bounded rounds and mixed contains all six kinds once',
    () {
      for (final difficulty in ChallengeDifficulty.values) {
        for (final kind in [ChallengeKind.mirror, ChallengeKind.captcha]) {
          final session = ChallengeSession(kind: kind, difficulty: difficulty);
          expect(
            session.totalSteps,
            difficulty == ChallengeDifficulty.hard ? 3 : 2,
          );
          expect(session.submitCorrect(), isFalse);
          session.submitIncorrect();
          expect(session.completedSteps, 1);
          while (!session.isComplete) {
            session.submitCorrect();
          }
          expect(session.submitCorrect(), isFalse);
        }
        final mixed = ChallengeSession(
          kind: ChallengeKind.mixed,
          difficulty: difficulty,
        );
        expect(
          mixed.rounds.toSet(),
          ChallengeKind.values
              .where((kind) => kind != ChallengeKind.mixed)
              .toSet(),
        );
        expect(mixed.rounds, hasLength(6));
      }
    },
  );
}
