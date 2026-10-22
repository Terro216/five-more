import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'challenge_models.dart';

/// An offline challenge flow. The host owns alarm playback and dismissal.
class ChallengeScreen extends StatefulWidget {
  const ChallengeScreen({
    super.key,
    required this.kind,
    required this.difficulty,
    required this.onComplete,
    this.onEmergencyExit,
    this.practice = false,
  });

  final ChallengeKind kind;
  final ChallengeDifficulty difficulty;
  final VoidCallback onComplete;
  final VoidCallback? onEmergencyExit;
  final bool practice;

  @override
  State<ChallengeScreen> createState() => _ChallengeScreenState();
}

class _ChallengeScreenState extends State<ChallengeScreen> {
  static const _background = Color(0xFF101612);
  static const _surface = Color(0xFF1C251E);
  static const _accent = Color(0xFFF3C96B);
  static const _text = Color(0xFFF6F4E9);
  static const _muted = Color(0xFFB7C0B5);

  final _random = Random();
  late final ChallengeSession _session;
  late ChallengeKind _activeKind;
  MathQuestion? _math;
  MemoryPattern? _memory;
  StroopQuestion? _stroop;
  SequenceBoard? _sequence;
  int _sequenceCompleted = 0;
  final _selected = <int>{};
  bool _showPattern = false;
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
    );
    _prepareRound();
  }

  @override
  void dispose() {
    _previewTimer?.cancel();
    _nextTimer?.cancel();
    super.dispose();
  }

  void _prepareRound() {
    _previewTimer?.cancel();
    _feedback = null;
    _transitioning = false;
    _selected.clear();
    _sequenceCompleted = 0;
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
      case ChallengeKind.mixed:
        throw StateError('A mixed session contains concrete task types');
    }
  }

  void _startPreview() {
    _previewTimer?.cancel();
    _showPattern = true;
    _selected.clear();
    _previewTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _showPattern = false);
    });
  }

  void _answer(bool correct) {
    if (_finished || _transitioning || _session.isComplete) return;
    if (!correct) {
      setState(() {
        _session.submitIncorrect();
        _feedback = 'Попробуй ещё раз. Пройденные шаги сохраняются.';
        _feedbackCorrect = false;
        if (_activeKind == ChallengeKind.memory) _selected.clear();
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
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (context) => AlertDialog(
        title: const Text('Остановить без задания?'),
        content: const Text(
          'Если нужно срочно выключить звук, можно выйти сейчас. '
          'Задание останется непройденным.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Продолжить задание'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Остановить'),
          ),
        ],
      ),
    );
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
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 16, 0),
                    child: Row(
                      children: [
                        const Icon(Icons.wb_twilight_rounded, color: _accent),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            widget.practice ? 'Пробный подъём' : 'Доброе утро',
                            style: const TextStyle(color: _muted, fontSize: 15),
                          ),
                        ),
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
                              _feedback ?? 'Без спешки. Ошибаться можно.',
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
                        label: const Text('Нужно срочно выключить'),
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

  Widget _buildMath() {
    final question = _math!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _instruction('Разомнём голову', 'Выбери правильный ответ'),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 38),
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.circular(28),
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
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.9,
          children: question.choices
              .map(
                (choice) => _answerButton(
                  label: '$choice',
                  onPressed: () => _answer(question.accepts(choice)),
                ),
              )
              .toList(),
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
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: pattern.cellCount,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: pattern.side,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
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
                              _showPattern ? Icons.circle : Icons.check_rounded,
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
        if (!_showPattern)
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
              swatch: _inkColor(choice),
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
      textStyle: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
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
