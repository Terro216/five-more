import 'dart:math';

/// Wake-up tasks contain no network, storage, or alarm dependencies.
enum ChallengeKind {
  math,
  memory,
  stroop,
  sequence,
  mirror,
  captcha,
  qr,
  shake,
  maze,
  flags,
  mixed,
}

extension ChallengeKindLabel on ChallengeKind {
  String get label => switch (this) {
    ChallengeKind.math => 'Счёт',
    ChallengeKind.memory => 'Память',
    ChallengeKind.stroop => 'Цвета',
    ChallengeKind.sequence => 'Порядок',
    ChallengeKind.mirror => 'Зеркальный текст',
    ChallengeKind.captcha => 'Код с картинки',
    ChallengeKind.qr => 'QR-код',
    ChallengeKind.shake => 'Тряска',
    ChallengeKind.maze => 'Лабиринт',
    ChallengeKind.flags => 'Флаги',
    ChallengeKind.mixed => 'Микс',
  };

  String get description => switch (this) {
    ChallengeKind.math => 'Несколько примеров, чтобы включить голову',
    ChallengeKind.memory => 'Запомни и повтори рисунок из клеток',
    ChallengeKind.stroop => 'Выбери цвет букв, а не написанное слово',
    ChallengeKind.sequence => 'Найди числа и нажми их по порядку',
    ChallengeKind.mirror =>
      'Прочитай отражённую фразу и введи её обычным текстом',
    ChallengeKind.captcha => 'Разбери и введи код из букв и цифр',
    ChallengeKind.qr => 'Дойди до заранее выбранного QR-кода и отсканируй его',
    ChallengeKind.shake => 'Разбуди телефон серией движений',
    ChallengeKind.maze => 'Наклоняй телефон и проведи шарик мимо отверстий',
    ChallengeKind.flags => 'Узнай страну по её флагу',
    ChallengeKind.mixed => 'Случайная очередь или свой порядок заданий',
  };
}

enum ChallengeDifficulty { easy, medium, hard, extreme }

extension ChallengeDifficultyLabel on ChallengeDifficulty {
  String get label => switch (this) {
    ChallengeDifficulty.easy => 'Чилл',
    ChallengeDifficulty.medium => 'Средне',
    ChallengeDifficulty.hard => 'Сложно',
    ChallengeDifficulty.extreme => 'Нереально',
  };

  String get description => switch (this) {
    ChallengeDifficulty.easy => 'Мягкий старт',
    ChallengeDifficulty.medium => 'Придётся проснуться',
    ChallengeDifficulty.hard => 'Счёт без подсказок и задания на концентрацию',
    ChallengeDifficulty.extreme => 'Больше шагов, меньше подсказок',
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
      final a = 12 + random.nextInt(19);
      final b = 7 + random.nextInt(9);
      final c = 2 + random.nextInt(12);
      if (random.nextBool()) {
        expression = '$a × $b − $c';
        answer = a * b - c;
      } else {
        expression = '$a × $b + $c';
        answer = a * b + c;
      }
    case ChallengeDifficulty.extreme:
      final a = 18 + random.nextInt(28);
      final b = 12 + random.nextInt(15);
      final c = 7 + random.nextInt(24);
      final d = 3 + random.nextInt(9);
      expression = '($a × $b) − ($c × $d)';
      answer = a * b - c * d;
  }

  final choices = <int>{answer};
  while (choices.length < 4) {
    final offset = 1 + random.nextInt(9);
    final candidate = answer + (random.nextBool() ? offset : -offset);
    choices.add(candidate);
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
  final side = [3, 4, 5, 6][difficulty.index];
  final count = switch (difficulty) {
    ChallengeDifficulty.easy => 3,
    ChallengeDifficulty.medium => 5,
    ChallengeDifficulty.hard => 10,
    ChallengeDifficulty.extreme => 16,
  };
  final candidates = List.generate(side * side, (index) => index)
    ..shuffle(random);
  return MemoryPattern(side: side, cells: candidates.take(count).toSet());
}

/// An immutable permutation of 1..cellCount, displayed in [columns] columns.
class SequenceBoard {
  SequenceBoard._({required this.columns, required List<int> numbers})
    : numbers = List.unmodifiable(numbers);

  final int columns;
  final List<int> numbers;

  int get cellCount => numbers.length;

  SequenceBoard reshuffleRemaining(Random random, int completed) {
    final remaining = numbers.where((n) => n > completed).toList()
      ..shuffle(random);
    final original = numbers.where((n) => n > completed).toList();
    if (remaining.length > 1 &&
        remaining.indexed.every((e) => e.$2 == original[e.$1])) {
      remaining.add(remaining.removeAt(0));
    }
    var next = 0;
    return SequenceBoard._(
      columns: columns,
      numbers: numbers
          .map((n) => n <= completed ? n : remaining[next++])
          .toList(),
    );
  }

  bool accepts(int candidate, {required int completedCount}) =>
      completedCount >= 0 &&
      completedCount < cellCount &&
      candidate == completedCount + 1;
}

SequenceBoard generateSequenceBoard(
  Random random,
  ChallengeDifficulty difficulty,
) {
  final count = switch (difficulty) {
    ChallengeDifficulty.easy => 6,
    ChallengeDifficulty.medium => 9,
    ChallengeDifficulty.hard => 16,
    ChallengeDifficulty.extreme => 25,
  };
  final numbers = List.generate(count, (index) => index + 1)..shuffle(random);
  // Even an unlucky shuffle must leave a search task, not a sorted keypad.
  if (numbers.indexed.every((entry) => entry.$2 == entry.$1 + 1)) {
    final first = numbers[0];
    numbers[0] = numbers[1];
    numbers[1] = first;
  }
  return SequenceBoard._(
    columns: difficulty.index >= 2 ? difficulty.index + 2 : 3,
    numbers: numbers,
  );
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
    ChallengeDifficulty.hard || ChallengeDifficulty.extreme => 5,
  };
  final colors = ChallengeInk.values.toList()..shuffle(random);
  final choices = colors.take(count).toList();
  // Always different: recognizing the word alone must never solve this task.
  final ink = choices[0];
  final word = choices[1];
  choices.shuffle(random);
  return StroopQuestion(word: word, ink: ink, choices: choices);
}

/// The stored phrase is ordinary text; only its visual presentation is mirrored.
/// Tolerate typing conventions, not missing words or reversed answers.
class MirrorTextQuestion {
  const MirrorTextQuestion(this.text);

  final String text;

  bool accepts(String candidate) =>
      _normalizePhrase(candidate) == _normalizePhrase(text);

  static String _normalizePhrase(String value) => value
      .trim()
      .toLowerCase()
      .replaceAll('ё', 'е')
      .replaceAll(RegExp(r'\s+'), ' ');
}

MirrorTextQuestion generateMirrorTextQuestion(
  Random random,
  ChallengeDifficulty difficulty, {
  String? previous,
}) {
  final phrases = switch (difficulty) {
    ChallengeDifficulty.easy => const [
      'пора вставать',
      'утро настало',
      'новый рассвет',
      'сон позади',
    ],
    ChallengeDifficulty.medium => const [
      'я выбираю ранний подъём',
      'сегодня утро начинается',
      'первый шаг уже сделан',
      'за окном начинается день',
    ],
    ChallengeDifficulty.extreme => const [
      'завтрашнее утро начинается с решения вовремя лечь спать сегодня',
      'я выбираю встать сейчас и подарить себе спокойное начало нового дня',
      'маленький шаг навстречу утру помогает сделать большой шаг к своей цели',
    ],
    ChallengeDifficulty.hard => const [
      'сегодня я встаю с первым звонком',
      'новое утро начинается с маленького шага',
      'я открываю глаза и начинаю новый день',
      'время просыпаться и встречать новый день',
    ],
  };
  final choices = phrases.where((phrase) => phrase != previous).toList();
  return MirrorTextQuestion(choices[random.nextInt(choices.length)]);
}

/// Excludes easily confused pairs such as O/0, I/l/1, B/8 and S/5.
const captchaLetters = 'ACEFHJKMNPRTUVWXY';
const captchaDigits = '34679';
const captchaAlphabet = '$captchaLetters$captchaDigits';

class CaptchaQuestion {
  CaptchaQuestion({
    required this.code,
    required List<double> rotations,
    required this.decorationSeed,
  }) : rotations = List.unmodifiable(rotations);

  final String code;
  final List<double> rotations;
  final int decorationSeed;

  bool accepts(String candidate) => candidate.trim().toUpperCase() == code;
}

CaptchaQuestion generateCaptchaQuestion(
  Random random,
  ChallengeDifficulty difficulty, {
  String? previous,
}) {
  final length = [4, 5, 8, 10][difficulty.index];
  String code;
  do {
    final characters = [
      captchaLetters[random.nextInt(captchaLetters.length)],
      captchaDigits[random.nextInt(captchaDigits.length)],
      for (var index = 2; index < length; index += 1)
        captchaAlphabet[random.nextInt(captchaAlphabet.length)],
    ]..shuffle(random);
    code = characters.join();
  } while (code == previous);
  return CaptchaQuestion(
    code: code,
    rotations: List.generate(length, (_) => (random.nextDouble() - .5) * .3),
    decorationSeed: random.nextInt(1 << 30),
  );
}

/// A mistake retries the preceding stage, bounded at the first stage.
class ChallengeSession {
  ChallengeSession({
    required this.kind,
    required this.difficulty,
    Random? random,
    List<ChallengeKind> order = const [],
  }) : rounds = _buildRounds(kind, difficulty, random ?? Random(), order);

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
    if (!isComplete) {
      _mistakes += 1;
      _completedSteps = max(0, _completedSteps - 1);
    }
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
    List<ChallengeKind> order,
  ) {
    if (kind == ChallengeKind.mixed) {
      final configured = order
          .where((k) => k != ChallengeKind.mixed)
          .take(12)
          .toList();
      if (configured.isNotEmpty) return List.unmodifiable(configured);
      final rounds = [
        ChallengeKind.math,
        ChallengeKind.memory,
        ChallengeKind.stroop,
        ChallengeKind.sequence,
        ChallengeKind.mirror,
        ChallengeKind.captcha,
        ChallengeKind.flags,
      ]..shuffle(random);
      return List.unmodifiable(rounds);
    }
    final count = switch (kind) {
      ChallengeKind.math => difficulty.index + 2,
      ChallengeKind.memory => difficulty.index >= 2 ? difficulty.index + 1 : 2,
      ChallengeKind.stroop => difficulty.index + 3,
      ChallengeKind.sequence =>
        difficulty.index >= 2 ? difficulty.index + 1 : 2,
      ChallengeKind.mirror => difficulty.index >= 2 ? difficulty.index + 1 : 2,
      ChallengeKind.captcha => difficulty.index >= 2 ? difficulty.index + 1 : 2,
      ChallengeKind.qr || ChallengeKind.shake || ChallengeKind.maze => 1,
      ChallengeKind.flags => 3 + difficulty.index * 2,
      ChallengeKind.mixed => throw StateError('Mixed rounds are handled above'),
    };
    return List.unmodifiable(List.filled(count, kind));
  }
}
