import 'dart:math';

/// Wake-up tasks contain no network, storage, or alarm dependencies.
enum ChallengeKind { math, memory, stroop, mixed }

extension ChallengeKindLabel on ChallengeKind {
  String get label => switch (this) {
    ChallengeKind.math => 'Счёт',
    ChallengeKind.memory => 'Память',
    ChallengeKind.stroop => 'Цвета',
    ChallengeKind.mixed => 'Микс',
  };

  String get description => switch (this) {
    ChallengeKind.math => 'Несколько примеров, чтобы включить голову',
    ChallengeKind.memory => 'Запомни и повтори рисунок из клеток',
    ChallengeKind.stroop => 'Выбери цвет букв, а не написанное слово',
    ChallengeKind.mixed => 'Счёт, память и цвета в случайном порядке',
  };
}

enum ChallengeDifficulty { easy, medium, hard }

extension ChallengeDifficultyLabel on ChallengeDifficulty {
  String get label => switch (this) {
    ChallengeDifficulty.easy => 'Легко',
    ChallengeDifficulty.medium => 'Средне',
    ChallengeDifficulty.hard => 'Сложно',
  };

  String get description => switch (this) {
    ChallengeDifficulty.easy => 'Мягкий старт',
    ChallengeDifficulty.medium => 'Придётся проснуться',
    ChallengeDifficulty.hard => 'Для любителей «ещё пять»',
  };
}

class MathQuestion {
  MathQuestion({
    required this.expression,
    required this.answer,
    required List<int> choices,
  }) : choices = List.unmodifiable(choices);

  final String expression;
  final int answer;
  final List<int> choices;

  bool accepts(int candidate) => candidate == answer;
}

MathQuestion generateMathQuestion(
  Random random,
  ChallengeDifficulty difficulty, {
  int round = 0,
}) {
  final int answer;
  final String expression;
  final boundedRound = round.clamp(0, 5);
  switch (difficulty) {
    case ChallengeDifficulty.easy:
      final a = 2 + random.nextInt(8 + boundedRound);
      final b = 2 + random.nextInt(8);
      if (random.nextBool()) {
        expression = '$a + $b';
        answer = a + b;
      } else {
        expression = '${a + b} − $a';
        answer = b;
      }
    case ChallengeDifficulty.medium:
      final a = 3 + random.nextInt(7);
      final b = 2 + random.nextInt(7);
      if (round.isEven) {
        expression = '$a × $b';
        answer = a * b;
      } else {
        final c = 5 + random.nextInt(16);
        expression = '${a + c} + $b';
        answer = a + c + b;
      }
    case ChallengeDifficulty.hard:
      final a = 4 + random.nextInt(9);
      final b = 3 + random.nextInt(7);
      final c = 2 + random.nextInt(12);
      if (random.nextBool()) {
        expression = '$a × $b − $c';
        answer = a * b - c;
      } else {
        expression = '${a * b} ÷ $b + $c';
        answer = a + c;
      }
  }

  final choices = <int>{answer};
  while (choices.length < 4) {
    final offset = 1 + random.nextInt(9);
    final candidate = answer + (random.nextBool() ? offset : -offset);
    if (candidate >= 0) choices.add(candidate);
  }
  return MathQuestion(
    expression: expression,
    answer: answer,
    choices: choices.toList()..shuffle(random),
  );
}

class MemoryPattern {
  MemoryPattern({required this.side, required Set<int> cells})
    : cells = Set.unmodifiable(cells);

  final int side;
  final Set<int> cells;

  int get cellCount => side * side;

  bool accepts(Set<int> selected) =>
      selected.length == cells.length && cells.containsAll(selected);
}

MemoryPattern generateMemoryPattern(
  Random random,
  ChallengeDifficulty difficulty,
) {
  final side = difficulty == ChallengeDifficulty.hard ? 4 : 3;
  final count = switch (difficulty) {
    ChallengeDifficulty.easy => 3,
    ChallengeDifficulty.medium => 4,
    ChallengeDifficulty.hard => 6,
  };
  final candidates = List.generate(side * side, (index) => index)
    ..shuffle(random);
  return MemoryPattern(side: side, cells: candidates.take(count).toSet());
}

enum ChallengeInk { red, blue, yellow, green, purple }

extension ChallengeInkLabel on ChallengeInk {
  String get label => switch (this) {
    ChallengeInk.red => 'Красный',
    ChallengeInk.blue => 'Синий',
    ChallengeInk.yellow => 'Жёлтый',
    ChallengeInk.green => 'Зелёный',
    ChallengeInk.purple => 'Фиолетовый',
  };
}

class StroopQuestion {
  StroopQuestion({
    required this.word,
    required this.ink,
    required List<ChallengeInk> choices,
  }) : choices = List.unmodifiable(choices);

  final ChallengeInk word;
  final ChallengeInk ink;
  final List<ChallengeInk> choices;

  bool accepts(ChallengeInk candidate) => candidate == ink;
}

StroopQuestion generateStroopQuestion(
  Random random,
  ChallengeDifficulty difficulty,
) {
  final count = switch (difficulty) {
    ChallengeDifficulty.easy => 3,
    ChallengeDifficulty.medium => 4,
    ChallengeDifficulty.hard => 5,
  };
  final colors = ChallengeInk.values.toList()..shuffle(random);
  final choices = colors.take(count).toList();
  // Always different: recognizing the word alone must never solve this task.
  final ink = choices[0];
  final word = choices[1];
  choices.shuffle(random);
  return StroopQuestion(word: word, ink: ink, choices: choices);
}

/// Mistakes never remove completed steps or create an impossible lockout.
class ChallengeSession {
  ChallengeSession({
    required this.kind,
    required this.difficulty,
    Random? random,
  }) : rounds = _buildRounds(kind, difficulty, random ?? Random());

  final ChallengeKind kind;
  final ChallengeDifficulty difficulty;
  final List<ChallengeKind> rounds;
  int _completedSteps = 0;
  int _mistakes = 0;

  int get completedSteps => _completedSteps;
  int get mistakes => _mistakes;
  int get totalSteps => rounds.length;
  bool get isComplete => _completedSteps >= totalSteps;
  double get progress => _completedSteps / totalSteps;
  ChallengeKind get currentKind =>
      rounds[_completedSteps.clamp(0, totalSteps - 1)];

  void submitIncorrect() {
    if (!isComplete) _mistakes += 1;
  }

  /// Returns true only when this answer completes the session.
  bool submitCorrect() {
    if (isComplete) return false;
    _completedSteps += 1;
    return isComplete;
  }

  static List<ChallengeKind> _buildRounds(
    ChallengeKind kind,
    ChallengeDifficulty difficulty,
    Random random,
  ) {
    if (kind == ChallengeKind.mixed) {
      final rounds = [
        ChallengeKind.math,
        ChallengeKind.memory,
        ChallengeKind.stroop,
      ]..shuffle(random);
      return List.unmodifiable(rounds);
    }
    final count = switch (kind) {
      ChallengeKind.math => difficulty.index + 2,
      ChallengeKind.memory => difficulty == ChallengeDifficulty.hard ? 3 : 2,
      ChallengeKind.stroop => difficulty.index + 3,
      ChallengeKind.mixed => throw StateError('Mixed rounds are handled above'),
    };
    return List.unmodifiable(List.filled(count, kind));
  }
}
