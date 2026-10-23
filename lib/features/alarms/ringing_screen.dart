import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/alarm_controller.dart';
import '../../app/theme.dart';
import '../../models/alarm.dart';
import '../../models/snooze_position.dart';
import '../challenges/challenge_models.dart';
import '../challenges/challenge_screen.dart';
import 'alarm_editor.dart';

class RingingScreen extends StatefulWidget {
  const RingingScreen({
    super.key,
    required this.controller,
    required this.ringing,
  });
  final AlarmController controller;
  final RingingAlarm ringing;

  @override
  State<RingingScreen> createState() => _RingingScreenState();
}

class _RingingScreenState extends State<RingingScreen> {
  bool _challenge = false;
  bool _emergency = false;
  bool _finishing = false;
  double _hold = 0;
  Timer? _holdTimer;
  Timer? _clockTimer;
  String? _error;
  String? _completedOccurrenceId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) FocusManager.instance.primaryFocus?.unfocus();
    });
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !_challenge && !_emergency) setState(() {});
    });
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _clockTimer?.cancel();
    super.dispose();
  }

  Future<void> _dismiss({bool emergency = false}) async {
    if (_finishing) return;
    setState(() {
      _finishing = true;
      _error = null;
    });
    final result = await widget.controller.dismiss(
      emergency: emergency,
      alarmId: widget.ringing.alarm.id,
      occurrenceId: widget.ringing.occurrenceId,
    );
    if (mounted && !result.ok) {
      setState(() {
        _finishing = false;
        _challenge = false;
        _emergency = false;
        _error =
            result.error ??
            'Не удалось отключить будильник. Попробуйте ещё раз.';
      });
    }
  }

  Future<void> _snooze() async {
    if (_finishing) return;
    setState(() {
      _finishing = true;
      _error = null;
    });
    final result = await widget.controller.snooze(
      alarmId: widget.ringing.alarm.id,
      occurrenceId: widget.ringing.occurrenceId,
    );
    if (mounted && !result.ok) {
      setState(() {
        _finishing = false;
        _error = result.error;
      });
    }
  }

  void _startHold() {
    if (_finishing) return;
    _holdTimer?.cancel();
    setState(() => _hold = 0);
    _holdTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final progress = (timer.tick / 40).clamp(0.0, 1.0);
      setState(() => _hold = progress);
      if (progress >= 1) {
        timer.cancel();
        unawaited(_dismiss(emergency: true));
      }
    });
  }

  void _stopHold() {
    _holdTimer?.cancel();
    if (mounted && !_finishing) setState(() => _hold = 0);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final ringing = widget.controller.ringing ?? widget.ringing;
        if (_challenge) {
          return ChallengeScreen(
            key: ValueKey(
              '${ringing.occurrenceId}:${ringing.challengeDifficulty.name}',
            ),
            kind: ringing.alarm.challengeKind,
            difficulty: ringing.challengeDifficulty,
            onComplete: () {
              _completedOccurrenceId = ringing.occurrenceId;
              _dismiss();
            },
            onEmergencyExit: () => _dismiss(emergency: true),
          );
        }
        if (_emergency) return _emergencyScreen();
        return Scaffold(
          backgroundColor: ink,
          resizeToAvoidBottomInset: false,
          bottomNavigationBar: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: TextButton(
                key: const ValueKey('ringing-emergency'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _finishing
                    ? null
                    : () => setState(() => _emergency = true),
                child: const Text(
                  'Аварийное отключение',
                  style: TextStyle(color: muted),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
          body: SafeArea(
            bottom: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final summary = SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
                      child: _ringSummary(ringing),
                    );
                    final actions = Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                      child: _ringActions(ringing),
                    );
                    if (constraints.maxWidth >= 600 &&
                        constraints.maxHeight < 600) {
                      return Row(
                        children: [
                          Expanded(child: summary),
                          Expanded(
                            child: SingleChildScrollView(child: actions),
                          ),
                        ],
                      );
                    }
                    return Column(
                      children: [
                        Expanded(child: Center(child: summary)),
                        actions,
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _ringSummary(RingingAlarm ringing) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Icon(Icons.wb_twilight_rounded, color: morning, size: 36),
      const SizedBox(height: 12),
      Text(
        ringing.alarm.id.startsWith('preview:')
            ? 'Проверка будильника'
            : 'Доброе утро',
        textAlign: TextAlign.center,
        style: const TextStyle(color: morning, fontSize: 16),
      ),
      const SizedBox(height: 12),
      FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          ringing.alarm.timeLabel,
          style: const TextStyle(
            fontSize: 72,
            fontWeight: FontWeight.w300,
            letterSpacing: -2,
            height: 1.1,
          ),
        ),
      ),
      const SizedBox(height: 12),
      Text(
        ringing.alarm.displayTitle,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 24),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            challengeIcon(ringing.alarm.challengeKind),
            color: morning,
            size: 20,
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              ringing.alarm.challengeKind.label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      Text(
        _challengeLevel(ringing),
        key: const ValueKey('ringing-challenge-level'),
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 14, color: muted),
      ),
      const SizedBox(height: 20),
      if (ringing.snoozesRemaining > 0) ...[
        Text(
          'Осталось переносов: ${ringing.snoozesRemaining} из ${ringing.alarm.maxSnoozes}'
          ' · ${ringing.snoozesRemaining * ringing.alarm.snoozeMinutes} мин',
          textAlign: TextAlign.center,
          style: const TextStyle(color: muted, fontSize: 14),
        ),
        const SizedBox(height: 8),
        Text(
          _snoozeTiming(ringing),
          textAlign: TextAlign.center,
          style: const TextStyle(color: morning, fontSize: 14, height: 1.4),
        ),
        if (ringing.alarm.moveSnoozeButton &&
            ringing.alarm.difficultyForSnoozes(ringing.snoozesUsed + 1) !=
                ringing.challengeDifficulty) ...[
          const SizedBox(height: 8),
          Text(
            'После переноса — ${ringing.alarm.difficultyForSnoozes(ringing.snoozesUsed + 1).label.toLowerCase()}.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: muted, fontSize: 14),
          ),
        ],
      ] else
        Text(
          ringing.alarm.maxSnoozes == 0
              ? 'Без переносов. Пройди задание, чтобы отключить звонок.'
              : 'Переносы закончились. Пройди задание, чтобы отключить звонок.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: muted, fontSize: 14, height: 1.4),
        ),
    ],
  );

  Widget _ringActions(RingingAlarm ringing) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 120),
            child: SingleChildScrollView(
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  key: const ValueKey('ringing-error'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
          ),
        ),
      FilledButton.icon(
        key: const ValueKey('ringing-start-challenge'),
        onPressed: _finishing || widget.controller.busy
            ? null
            : _completedOccurrenceId == ringing.occurrenceId
            ? () => _dismiss()
            : () => setState(() => _challenge = true),
        icon: const Icon(Icons.arrow_forward_rounded),
        label: Text(
          _completedOccurrenceId == ringing.occurrenceId
              ? 'Повторить отключение'
              : 'Пройти задание',
          textAlign: TextAlign.center,
        ),
      ),
      if (ringing.snoozesRemaining > 0) ...[
        const SizedBox(height: 10),
        _snoozeControl(ringing),
      ],
    ],
  );

  Widget _snoozeControl(RingingAlarm ringing) {
    final onPressed = _finishing || widget.controller.busy ? null : _snooze;
    if (!ringing.alarm.moveSnoozeButton) {
      return OutlinedButton.icon(
        key: const ValueKey('ringing-snooze'),
        onPressed: onPressed,
        icon: const Icon(Icons.snooze_rounded),
        label: Text(_snoozeLabel(ringing), textAlign: TextAlign.center),
      );
    }
    final position = snoozePositionFor(
      ringing.occurrenceId,
      ringing.snoozesUsed,
    );
    // Reserve the full area for the current ring. There is no animation,
    // timer-driven relocation, or layout change while a press is in progress.
    return LayoutBuilder(
      builder: (context, constraints) => Padding(
        key: const ValueKey('moving-snooze-area'),
        padding: EdgeInsets.only(
          top: position.onBottom ? 16 : 0,
          bottom: position.onBottom ? 0 : 16,
        ),
        child: Align(
          alignment: position.onRight
              ? Alignment.centerRight
              : Alignment.centerLeft,
          child: SizedBox(
            width: constraints.maxWidth * .6,
            child: OutlinedButton(
              key: const ValueKey('ringing-snooze'),
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(48, 50),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
              ),
              child: Text(
                'Ещё ${ringing.alarm.snoozeMinutes} мин',
                semanticsLabel: _snoozeLabel(ringing),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _challengeLevel(RingingAlarm ringing) {
    final level = ringing.challengeDifficulty.label;
    final used = ringing.snoozesUsed;
    if (!ringing.alarm.escalateOnSnooze || used == 0) {
      return '$level · пройди, чтобы отключить';
    }
    return used == 1
        ? '$level · после 1 переноса'
        : '$level · после $used переносов';
  }

  String _snoozeLabel(RingingAlarm ringing) {
    final nextLevel = ringing.alarm.difficultyForSnoozes(
      ringing.snoozesUsed + 1,
    );
    final label = 'Ещё ${ringing.alarm.snoozeMinutes} минут';
    return nextLevel != ringing.challengeDifficulty
        ? '$label · затем ${nextLevel.label.toLowerCase()}'
        : label;
  }

  String _snoozeTiming(RingingAlarm ringing) {
    final now = widget.controller.now;
    final next = now.add(Duration(minutes: ringing.alarm.snoozeMinutes));
    final last = now.add(
      Duration(minutes: ringing.alarm.snoozeMinutes * ringing.snoozesRemaining),
    );
    String clock(DateTime value) =>
        '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
    return ringing.snoozesRemaining == 1
        ? 'Если перенести сейчас, последний звонок — в ${clock(next)}.'
        : 'Если перенести сейчас — ${clock(next)}. '
              'Все оставшиеся переносы подряд — до ${clock(last)}.';
  }

  Widget _emergencyScreen() => Scaffold(
    backgroundColor: ink,
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.volume_off_outlined, color: morning, size: 54),
                const SizedBox(height: 24),
                const Text(
                  'Отключить без задания?',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 27, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Если сейчас не до задач, удерживай кнопку две секунды. '
                  'Будильник остановится, а в истории появится аварийное отключение.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: muted, height: 1.6),
                ),
                const SizedBox(height: 30),
                Semantics(
                  button: true,
                  label: 'Удерживайте две секунды, чтобы отключить будильник',
                  onLongPress: () => _dismiss(emergency: true),
                  child: GestureDetector(
                    onLongPressStart: (_) => _startHold(),
                    onLongPressEnd: (_) => _stopHold(),
                    onLongPressCancel: _stopHold,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: panel,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: morning.withValues(alpha: .4),
                        ),
                      ),
                      child: Column(
                        children: [
                          Text(
                            _finishing
                                ? 'Отключаем…'
                                : 'Удерживай, чтобы отключить',
                            style: const TextStyle(
                              color: morning,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 14),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: LinearProgressIndicator(
                              value: _hold,
                              minHeight: 5,
                              backgroundColor: ink,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: _finishing
                      ? null
                      : () {
                          _stopHold();
                          setState(() => _emergency = false);
                        },
                  child: const Text('Вернуться к будильнику'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
