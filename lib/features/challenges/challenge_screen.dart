import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import 'challenge_models.dart';
import 'physical_tasks.dart';
import 'flag_task.dart';
import '../../services/phrase_library.dart';
import '../../widgets/emergency_stop.dart';

/// An offline challenge flow. The host owns alarm playback and dismissal.
class ChallengeScreen extends StatefulWidget {
  const ChallengeScreen({
    super.key,
    required this.kind,
    required this.difficulty,
    required this.onComplete,
    this.onEmergencyExit,
    this.practice = false,
    this.order = const [],
    this.qrValue = '',
  });

  final ChallengeKind kind;
  final ChallengeDifficulty difficulty;
  final VoidCallback onComplete;
  final VoidCallback? onEmergencyExit;
  final bool practice;
  final List<ChallengeKind> order;
  final String qrValue;

  @override
  State<ChallengeScreen> createState() => _ChallengeScreenState();
}

class _ChallengeScreenState extends State<ChallengeScreen> {
  static const _background = ink;
  static const _surface = panel;
  static const _accent = morning;
  static const _text = foreground;
  static const _muted = muted;

  final _random = Random();
  late final ChallengeSession _session;
  late ChallengeKind _activeKind;
  MathQuestion? _math;
  MemoryPattern? _memory;
  StroopQuestion? _stroop;
  SequenceBoard? _sequence;
  MirrorTextQuestion? _mirror;
  CaptchaQuestion? _captcha;
  final _typedAnswer = TextEditingController();
  final _typedFocus = FocusNode();
  int _sequenceCompleted = 0;
  int _roundSerial = 0;
  String? _practiceQr;
  bool get _hard => widget.difficulty.index >= 2;
  final _selected = <int>{};
  bool _showPattern = false;
  bool _accessibleNavigation = false;
  bool _transitioning = false;
  bool _finished = false;
  bool _completionReady = false;
  bool _emergencyDialogOpen = false;
  String? _feedback;
  bool _feedbackCorrect = false;
  Timer? _previewTimer;
  Timer? _nextTimer;

  @override
  void initState() {
    super.initState();
    _session = ChallengeSession(
      kind: widget.kind,
      difficulty: widget.difficulty,
      random: _random,
      order: widget.order,
    );
    _prepareRound();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final accessibleNavigation = MediaQuery.accessibleNavigationOf(context);
    if (_accessibleNavigation == accessibleNavigation) return;
    _accessibleNavigation = accessibleNavigation;
    if (_activeKind == ChallengeKind.memory && _showPattern) {
      _schedulePreviewEnd();
    }
  }

  @override
  void dispose() {
    _previewTimer?.cancel();
    _nextTimer?.cancel();
    _typedAnswer.dispose();
    _typedFocus.dispose();
    super.dispose();
  }

  void _prepareRound() {
    _roundSerial++;
    _previewTimer?.cancel();
    _feedback = null;
    _transitioning = false;
    _selected.clear();
    _sequenceCompleted = 0;
    _typedAnswer.clear();
    _activeKind = _session.currentKind;
    switch (_activeKind) {
      case ChallengeKind.math:
        _math = generateMathQuestion(
          _random,
          widget.difficulty,
          round: _session.completedSteps,
        );
      case ChallengeKind.memory:
        _memory = generateMemoryPattern(_random, widget.difficulty);
        _startPreview();
      case ChallengeKind.stroop:
        _stroop = generateStroopQuestion(_random, widget.difficulty);
      case ChallengeKind.sequence:
        _sequence = generateSequenceBoard(_random, widget.difficulty);
      case ChallengeKind.mirror:
        _mirror = PhraseLibrary.instance.next(
          _random,
          widget.difficulty,
          previous: _mirror?.text,
        );
      case ChallengeKind.captcha:
        _captcha = generateCaptchaQuestion(
          _random,
          widget.difficulty,
          previous: _captcha?.code,
        );
      case ChallengeKind.qr:
      case ChallengeKind.shake:
      case ChallengeKind.maze:
      case ChallengeKind.flags:
        break;
      case ChallengeKind.mixed:
        throw StateError('A mixed session contains concrete task types');
    }
    if (_activeKind != ChallengeKind.mirror &&
        _activeKind != ChallengeKind.captcha) {
      _typedFocus.unfocus();
    }
  }

  void _startPreview() {
    _showPattern = true;
    _selected.clear();
    _schedulePreviewEnd();
  }

  void _schedulePreviewEnd() {
    _previewTimer?.cancel();
    _previewTimer = null;
    if (_accessibleNavigation) return;
    _previewTimer = Timer(
      Duration(milliseconds: [5000, 4000, 2500, 1800][widget.difficulty.index]),
      () {
        if (mounted) setState(() => _showPattern = false);
      },
    );
  }

  void _answer(bool correct) {
    if (_finished || _transitioning || _session.isComplete) return;
    if (!correct) {
      setState(() {
        _session.submitIncorrect();
        _prepareRound();
        _feedback = _session.completedSteps == 0
            ? 'Ошибка. Начни с первого этапа.'
            : 'Ошибка. Один этап назад.';
        _feedbackCorrect = false;
      });
      return;
    }
    final complete = _session.submitCorrect();
    setState(() {
      _transitioning = true;
      _feedbackCorrect = true;
      _feedback = complete ? 'Готово. Доброе утро!' : 'Верно. Ещё немного.';
    });
    _nextTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted || _finished) return;
      if (complete) {
        _completionReady = true;
        _deliverCompletion();
      } else {
        setState(_prepareRound);
      }
    });
  }

  void _deliverCompletion() {
    if (!_completionReady || _finished || _emergencyDialogOpen) return;
    _finished = true;
    _typedFocus.unfocus();
    widget.onComplete();
  }

  void _tapSequence(SequenceBoard board, int number) {
    if (_finished ||
        _transitioning ||
        _session.isComplete ||
        !identical(board, _sequence) ||
        number <= _sequenceCompleted) {
      return;
    }
    if (!board.accepts(number, completedCount: _sequenceCompleted)) {
      _answer(false);
      return;
    }
    setState(() {
      _sequenceCompleted += 1;
      if (_hard && _sequenceCompleted < board.cellCount) {
        _sequence = board.reshuffleRemaining(_random, _sequenceCompleted);
      }
      _feedback = null;
      _feedbackCorrect = false;
    });
    if (_sequenceCompleted == board.cellCount) _answer(true);
  }

  Future<void> _confirmEmergencyExit() async {
    if (widget.onEmergencyExit == null || _finished || _emergencyDialogOpen) {
      return;
    }
    _emergencyDialogOpen = true;
    _typedFocus.unfocus();
    final confirmed = await confirmEmergencyStop(context);
    _emergencyDialogOpen = false;
    if (!mounted || _finished) return;
    if (confirmed == true) {
      _finished = true;
      _previewTimer?.cancel();
      _nextTimer?.cancel();
      widget.onEmergencyExit?.call();
    } else {
      _deliverCompletion();
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final currentNumber = (_session.completedSteps + (_transitioning ? 0 : 1))
        .clamp(1, _session.totalSteps);
    return PopScope(
      canPop: widget.practice,
      child: Scaffold(
        backgroundColor: _background,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                children: [
                  if (!keyboardVisible || widget.practice)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 16, 16, 0),
                      child: Row(
                        children: [
                          if (!keyboardVisible) ...[
                            const Icon(
                              Icons.wb_twilight_rounded,
                              color: _accent,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                widget.practice
                                    ? 'Пробный подъём'
                                    : 'Доброе утро',
                                style: const TextStyle(
                                  color: _muted,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                          ] else
                            const Spacer(),
                          if (widget.practice)
                            IconButton(
                              tooltip: 'Закрыть тренировку',
                              onPressed: () => Navigator.maybePop(context),
                              icon: const Icon(Icons.close, color: _muted),
                            ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  widget.kind.label,
                                  style: const TextStyle(
                                    color: _text,
                                    fontSize: 34,
                                    height: 1.1,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                '$currentNumber / ${_session.totalSteps}',
                                style: const TextStyle(
                                  color: _accent,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: LinearProgressIndicator(
                              value: _session.progress,
                              minHeight: 5,
                              color: _accent,
                              backgroundColor: _surface,
                              semanticsLabel:
                                  'Пройдено заданий: ${_session.completedSteps} из ${_session.totalSteps}',
                            ),
                          ),
                          const SizedBox(height: 30),
                          IgnorePointer(
                            ignoring: _transitioning,
                            child: _buildTask(),
                          ),
                          const SizedBox(height: 20),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              _feedback ?? '',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: _feedbackCorrect ? _accent : _muted,
                                fontSize: 14,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (!widget.practice && widget.onEmergencyExit != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: TextButton.icon(
                        onPressed: _confirmEmergencyExit,
                        style: TextButton.styleFrom(
                          foregroundColor: _muted,
                          minimumSize: const Size(48, 48),
                        ),
                        icon: const Icon(Icons.volume_off_outlined, size: 18),
                        label: const Text('Не получается пройти'),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTask() => switch (_activeKind) {
    ChallengeKind.math => _buildMath(),
    ChallengeKind.memory => _buildMemory(),
    ChallengeKind.stroop => _buildStroop(),
    ChallengeKind.sequence => _buildSequence(),
    ChallengeKind.mirror => _buildTextTask(mirrored: true),
    ChallengeKind.captcha => _buildTextTask(mirrored: false),
    ChallengeKind.qr =>
      widget.qrValue.isEmpty && _practiceQr == null
          ? QrTask(
              key: ValueKey('qr-register-$_roundSerial'),
              onMatched: (code) => setState(() => _practiceQr = code),
            )
          : QrTask(
              key: ValueKey('qr-check-$_roundSerial'),
              expected: widget.qrValue.isEmpty ? _practiceQr : widget.qrValue,
              onMatched: (_) => _answer(true),
              onMistake: () => _answer(false),
            ),
    ChallengeKind.shake => ShakeTask(
      key: ValueKey('shake-$_roundSerial'),
      difficulty: widget.difficulty,
      onComplete: () => _answer(true),
    ),
    ChallengeKind.maze => MazeTask(
      key: ValueKey('maze-$_roundSerial'),
      difficulty: widget.difficulty,
      practice: widget.practice,
      onComplete: () => _answer(true),
      onMistake: () => _answer(false),
    ),
    ChallengeKind.flags => FlagTask(
      key: ValueKey('flags-$_roundSerial'),
      difficulty: widget.difficulty,
      onAnswer: _answer,
    ),
    ChallengeKind.mixed => const SizedBox.shrink(),
  };

  Widget _instruction(String title, String subtitle) => Column(
    children: [
      Text(
        title,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: _text,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        subtitle,
        textAlign: TextAlign.center,
        style: const TextStyle(color: _muted, fontSize: 15, height: 1.5),
      ),
    ],
  );

  void _submitTextAnswer() {
    if (_finished || _transitioning || _session.isComplete) return;
    final correct = switch (_activeKind) {
      ChallengeKind.mirror => _mirror!.accepts(_typedAnswer.text),
      ChallengeKind.captcha => _captcha!.accepts(_typedAnswer.text),
      _ => false,
    };
    _answer(correct);
  }

  Widget _buildTextTask({required bool mirrored}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        mirrored
            ? 'Прочитай отражённую фразу и введи её обычным текстом.'
            : 'Введи буквы и цифры с картинки. Буквы — латинские.',
        textAlign: TextAlign.center,
        style: const TextStyle(color: _muted, fontSize: 15, height: 1.5),
      ),
      const SizedBox(height: 20),
      Semantics(
        label: mirrored
            ? 'Зеркальная фраза для визуального чтения'
            : 'Картинка с кодом для визуального чтения',
        image: true,
        child: ExcludeSemantics(
          child: Container(
            key: ValueKey(mirrored ? 'mirror-prompt' : 'captcha-prompt'),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(16),
            ),
            child: mirrored
                ? Transform.flip(
                    key: const ValueKey('mirror-reflection'),
                    flipX: true,
                    child: Text(
                      _mirror!.text,
                      key: const ValueKey('mirror-phrase'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: _text,
                        fontSize: 26,
                        height: 1.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                : _captchaImage(_captcha!),
          ),
        ),
      ),
      const SizedBox(height: 20),
      TextField(
        key: const ValueKey('typed-challenge-answer'),
        controller: _typedAnswer,
        focusNode: _typedFocus,
        readOnly: _transitioning || _finished,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        autofillHints: const [],
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        keyboardType: mirrored
            ? TextInputType.text
            : TextInputType.visiblePassword,
        textCapitalization: mirrored
            ? TextCapitalization.none
            : TextCapitalization.characters,
        textInputAction: TextInputAction.done,
        maxLength: mirrored ? 160 : 12,
        inputFormatters: mirrored
            ? null
            : [FilteringTextInputFormatter.allow(RegExp('[a-zA-Z0-9]'))],
        decoration: InputDecoration(
          labelText: mirrored ? 'Ответ' : 'Код',
          floatingLabelBehavior: FloatingLabelBehavior.never,
          helperText: 'Регистр не важен',
          errorText: _feedback != null && !_feedbackCorrect
              ? 'Неверный ответ'
              : null,
          errorMaxLines: 3,
          counterText: '',
        ),
        onSubmitted: (_) => _submitTextAnswer(),
      ),
      const SizedBox(height: 14),
      FilledButton(
        key: const ValueKey('typed-challenge-submit'),
        onPressed: _transitioning || _finished ? null : _submitTextAnswer,
        child: const Text('Проверить ответ'),
      ),
      if (_accessibleNavigation) ...[
        const SizedBox(height: 16),
        const Text(
          'Это визуальное задание. В тренировке можно выбрать другое. '
          'Во время звонка доступно аварийное отключение.',
          style: TextStyle(color: _muted, height: 1.5),
        ),
      ],
    ],
  );

  Widget _captchaImage(CaptchaQuestion question) => CustomPaint(
    foregroundPainter: _CaptchaLines(seed: question.decorationSeed),
    child: Row(
      key: const ValueKey('captcha-glyphs'),
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (var index = 0; index < question.code.length; index += 1)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Transform.rotate(
                angle: question.rotations[index],
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    question.code[index],
                    key: ValueKey('captcha-glyph-$index'),
                    style: const TextStyle(
                      color: _text,
                      fontSize: 34,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _buildMath() {
    final question = _math!;
    if (_hard) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Введи ответ',
            textAlign: TextAlign.center,
            style: TextStyle(color: muted),
          ),
          const SizedBox(height: 20),
          Text(
            question.expression,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 24),
          TextField(
            key: const ValueKey('math-answer-input'),
            controller: _typedAnswer,
            focusNode: _typedFocus,
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            autocorrect: false,
            enableSuggestions: false,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[-0-9]')),
              LengthLimitingTextInputFormatter(8),
            ],
            decoration: const InputDecoration(labelText: 'Ответ'),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) =>
                _answer(int.tryParse(_typedAnswer.text) == question.answer),
          ),
          const SizedBox(height: 12),
          _answerButton(
            label: 'Проверить',
            accent: true,
            onPressed: () =>
                _answer(int.tryParse(_typedAnswer.text) == question.answer),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Выбери правильный ответ',
          textAlign: TextAlign.center,
          style: TextStyle(color: _muted, fontSize: 15, height: 1.5),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.circular(16),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              question.expression,
              style: const TextStyle(
                color: _text,
                fontSize: 42,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, constraints) {
            final cellWidth = (constraints.maxWidth - 12) / 2;
            var cellHeight = max(62.0, cellWidth / 1.9);
            for (final choice in question.choices) {
              final painter = TextPainter(
                text: TextSpan(text: '$choice', style: _answerTextStyle),
                textDirection: Directionality.of(context),
                textScaler: MediaQuery.textScalerOf(context),
                textAlign: TextAlign.center,
              )..layout(maxWidth: max(1.0, cellWidth - 40));
              cellHeight = max(cellHeight, painter.height + 32);
              painter.dispose();
            }
            return GridView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                mainAxisExtent: cellHeight,
              ),
              children: question.choices
                  .map(
                    (choice) => _answerButton(
                      label: '$choice',
                      onPressed: () => _answer(question.accepts(choice)),
                    ),
                  )
                  .toList(),
            );
          },
        ),
      ],
    );
  }

  Widget _buildMemory() {
    final pattern = _memory!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _instruction(
          _showPattern ? 'Запомни рисунок' : 'Повтори рисунок',
          _showPattern
              ? 'Здесь ${pattern.cells.length} отмеченных клеток'
              : 'Выбрано ${_selected.length} из ${pattern.cells.length}',
        ),
        const SizedBox(height: 24),
        LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: max(
                min(360.0, constraints.maxWidth),
                pattern.side * 48.0 + (pattern.side - 1) * 6.0,
              ),
              child: GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: pattern.cellCount,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: pattern.side,
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                ),
                itemBuilder: (context, index) {
                  final marked = _showPattern
                      ? pattern.cells.contains(index)
                      : _selected.contains(index);
                  return Semantics(
                    button: !_showPattern,
                    selected: marked,
                    label:
                        'Ряд ${index ~/ pattern.side + 1}, '
                        'столбец ${index % pattern.side + 1}',
                    child: Material(
                      color: marked ? _accent : _surface,
                      borderRadius: BorderRadius.circular(16),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: _showPattern
                            ? null
                            : () => setState(() {
                                _feedback = null;
                                if (!_selected.remove(index) &&
                                    _selected.length < pattern.cells.length) {
                                  _selected.add(index);
                                }
                              }),
                        child: marked
                            ? Icon(
                                _showPattern
                                    ? Icons.circle
                                    : Icons.check_rounded,
                                color: _background,
                                size: _showPattern ? 16 : 30,
                              )
                            : const SizedBox.expand(),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        _answerButton(
          label: _showPattern ? 'Запомнил, начнём' : 'Проверить',
          accent: true,
          onPressed: _showPattern
              ? () {
                  _previewTimer?.cancel();
                  setState(() => _showPattern = false);
                }
              : _selected.length == pattern.cells.length
              ? () => _answer(pattern.accepts(_selected))
              : null,
        ),
        if (!_showPattern && !_hard)
          TextButton(
            onPressed: () => setState(_startPreview),
            style: TextButton.styleFrom(
              foregroundColor: _muted,
              minimumSize: const Size(48, 48),
            ),
            child: const Text('Посмотреть ещё раз'),
          ),
      ],
    );
  }

  Widget _buildStroop() {
    final question = _stroop!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _instruction('Какого цвета буквы?', 'Не спеши читать само слово'),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 38),
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Semantics(
            label:
                'Написано ${question.word.label}. '
                'Цвет букв ${question.ink.label}. Выбери цвет букв.',
            excludeSemantics: true,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                question.word.label.toUpperCase(),
                style: TextStyle(
                  color: _inkColor(question.ink),
                  fontSize: 38,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        ...question.choices.map(
          (choice) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _answerButton(
              label: choice.label,
              swatch: _hard ? null : _inkColor(choice),
              onPressed: () => _answer(question.accepts(choice)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSequence() {
    final board = _sequence!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _instruction(
          'Нажимай по порядку',
          'От 1 до ${board.cellCount}. Найди следующее число.',
        ),
        const SizedBox(height: 16),
        Semantics(
          liveRegion: true,
          child: Text(
            _sequenceCompleted == board.cellCount
                ? 'Все числа найдены'
                : 'Следующее: ${_sequenceCompleted + 1}',
            key: const ValueKey('sequence-next'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _accent,
              fontSize: 19,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 20),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: board.cellCount,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: board.columns,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
              ),
              itemBuilder: (context, index) {
                final number = board.numbers[index];
                final completed = number <= _sequenceCompleted;
                final enabled = !completed && !_transitioning && !_finished;
                void tap() => _tapSequence(board, number);
                return Semantics(
                  key: ValueKey('sequence-number-$number'),
                  button: true,
                  selected: completed,
                  enabled: enabled,
                  label: 'Число $number',
                  value: completed ? 'Выбрано' : 'Не выбрано',
                  excludeSemantics: true,
                  onTap: enabled ? tap : null,
                  child: Material(
                    color: completed ? _accent : _surface,
                    borderRadius: BorderRadius.circular(16),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: enabled ? tap : null,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Text(
                            '$number',
                            style: TextStyle(
                              color: completed ? _background : _text,
                              fontSize: 26,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (completed)
                            const Positioned(
                              top: 6,
                              right: 6,
                              child: Icon(
                                Icons.check_rounded,
                                color: _background,
                                size: 14,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  TextStyle get _answerTextStyle =>
      Theme.of(context).textTheme.labelLarge!
          .copyWith(fontSize: 19, fontWeight: FontWeight.w600);

  Widget _answerButton({
    required String label,
    required VoidCallback? onPressed,
    Color? swatch,
    bool accent = false,
  }) => FilledButton(
    onPressed: onPressed,
    style: FilledButton.styleFrom(
      backgroundColor: accent ? _accent : _surface,
      foregroundColor: accent ? _background : _text,
      disabledBackgroundColor: _surface,
      disabledForegroundColor: _muted.withValues(alpha: 0.5),
      minimumSize: const Size(64, 62),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      textStyle: _answerTextStyle,
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (swatch != null) ...[
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(color: swatch, shape: BoxShape.circle),
          ),
          const SizedBox(width: 12),
        ],
        Flexible(child: Text(label, textAlign: TextAlign.center)),
      ],
    ),
  );

  Color _inkColor(ChallengeInk ink) => switch (ink) {
    ChallengeInk.red => const Color(0xFFFF8C8C),
    ChallengeInk.blue => const Color(0xFF7FBFFF),
    ChallengeInk.yellow => const Color(0xFFFFDA7A),
    ChallengeInk.green => const Color(0xFF8EDDAB),
    ChallengeInk.purple => const Color(0xFFD5ABFF),
  };
}

class _CaptchaLines extends CustomPainter {
  const _CaptchaLines({required this.seed});

  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final random = Random(seed);
    final paint = Paint()
      ..color = muted.withValues(alpha: .35)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    for (var line = 0; line < 3; line += 1) {
      final startY = size.height * (.2 + random.nextDouble() * .6);
      final endY = size.height * (.2 + random.nextDouble() * .6);
      final path = Path()
        ..moveTo(0, startY)
        ..quadraticBezierTo(
          size.width / 2,
          size.height * random.nextDouble(),
          size.width,
          endY,
        );
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _CaptchaLines oldDelegate) =>
      seed != oldDelegate.seed;
}
