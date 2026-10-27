import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/alarm_controller.dart';
import '../../app/theme.dart';
import '../../models/alarm.dart';
import '../../models/snooze_position.dart';
import '../challenges/challenge_models.dart';
import '../challenges/challenge_screen.dart';
import 'alarm_editor.dart';
import '../../widgets/emergency_stop.dart';
import '../../widgets/time_composer.dart';

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
  bool _snoozeEditing = false;
  int _chosenMinutes = 5;
  bool _finishing = false;
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
      minutes: _snoozeEditing ? _chosenMinutes : null,
    );
    if (mounted && !result.ok) {
      setState(() {
        _finishing = false;
        _error = result.error;
      });
    }
  }

  Future<void> _emergencyStop() async {
    if (_finishing || _emergency) return;
    setState(() => _emergency = true);
    final confirmed = await confirmEmergencyStop(context);
    if (!mounted) return;
    setState(() => _emergency = false);
    if (confirmed) await _dismiss(emergency: true);
  }

  void _editSnooze(RingingAlarm ringing) {
    if (_finishing) return;
    setState(() {
      _chosenMinutes = ringing.alarm.snoozeMinutes;
      _snoozeEditing = true;
    });
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
            order: ringing.alarm.mixOrder,
            qrValue: ringing.alarm.qrValue,
            onComplete: () {
              _completedOccurrenceId = ringing.occurrenceId;
              _dismiss();
            },
            onEmergencyExit: () => _dismiss(emergency: true),
          );
        }
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
                onPressed: _finishing ? null : _emergencyStop,
                child: const Text(
                  'Не получается пройти',
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
                    if (_snoozeEditing) {
                      return SingleChildScrollView(child: actions);
                    }
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
          'Осталось переносов: ${ringing.snoozesRemaining} из ${ringing.alarm.maxSnoozes}',
          textAlign: TextAlign.center,
          style: const TextStyle(color: muted, fontSize: 14),
        ),
        const SizedBox(height: 8),
        Text(
          _snoozeTiming(ringing),
          textAlign: TextAlign.center,
          style: const TextStyle(color: morning, fontSize: 14, height: 1.4),
        ),
        const SizedBox(height: 8),
        const Text(
          'Удерживай кнопку переноса, чтобы выбрать минуты',
          textAlign: TextAlign.center,
          style: TextStyle(color: muted, fontSize: 12),
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
          !widget.controller.device.challengeEnforced
              ? 'Переносов нет. Можно пройти задание здесь или остановить звонок системной кнопкой iOS.'
              : ringing.alarm.maxSnoozes == 0
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
    if (_snoozeEditing) {
      final next = widget.controller.now.add(Duration(minutes: _chosenMinutes));
      return Container(
        key: const ValueKey('snooze-slider'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: panel,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            Text(
              'Ещё $_chosenMinutes мин · звонок в ${clockLabel(TimeOfDay.fromDateTime(next))}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: morning),
            ),
            Slider(
              value: _chosenMinutes.toDouble(),
              min: 1,
              max: 30,
              divisions: 29,
              label: '$_chosenMinutes мин',
              onChanged: _finishing
                  ? null
                  : (v) => setState(() => _chosenMinutes = v.round()),
            ),
            Text(
              'После этого останется переносов: ${ringing.snoozesRemaining - 1}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: muted, fontSize: 12),
            ),
            Wrap(
              spacing: 8,
              alignment: WrapAlignment.center,
              children: [
                TextButton(
                  onPressed: _finishing
                      ? null
                      : () => setState(() => _snoozeEditing = false),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: _finishing ? null : _snooze,
                  child: Text('Отложить на $_chosenMinutes мин'),
                ),
              ],
            ),
          ],
        ),
      );
    }
    final onPressed = _finishing || widget.controller.busy ? null : _snooze;
    if (!ringing.alarm.moveSnoozeButton) {
      return OutlinedButton.icon(
        key: const ValueKey('ringing-snooze'),
        onLongPress: onPressed == null ? null : () => _editSnooze(ringing),
        onPressed: onPressed,
        icon: const Icon(Icons.snooze_rounded),
        label: Text(_snoozeLabel(ringing), textAlign: TextAlign.center),
      );
    }
    final appearance = snoozeAppearanceFor(
      ringing.occurrenceId,
      ringing.snoozesUsed,
    );
    const colors = [
      morning,
      Color(0xFF8EDDAB),
      Color(0xFF7FBFFF),
      Color(0xFFD5ABFF),
      Color(0xFFFFB4AB),
    ];
    return LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        key: const ValueKey('moving-snooze-area'),
        height: 168,
        child: Align(
          alignment: Alignment(appearance.x, appearance.y),
          child: SizedBox(
            width: (constraints.maxWidth * appearance.widthFactor).clamp(
              100.0,
              constraints.maxWidth,
            ),
            child: FilledButton(
              key: const ValueKey('ringing-snooze'),
              onPressed: onPressed,
              onLongPress: onPressed == null
                  ? null
                  : () => _editSnooze(ringing),
              style: FilledButton.styleFrom(
                backgroundColor: colors[appearance.colorIndex],
                foregroundColor: ink,
                minimumSize: Size(48, appearance.height),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(appearance.radius),
                ),
              ),
              child: Text(
                'Ещё ${ringing.alarm.snoozeMinutes} мин',
                semanticsLabel:
                    '${_snoozeLabel(ringing)}. Удерживай, чтобы выбрать минуты.',
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
    if (!widget.controller.device.challengeEnforced) {
      return '$level · системная остановка iOS тоже доступна';
    }
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
    final minutes = _snoozeEditing
        ? _chosenMinutes
        : ringing.alarm.snoozeMinutes;
    final next = now.add(Duration(minutes: minutes));
    final last = now.add(
      Duration(
        minutes:
            minutes +
            ringing.alarm.snoozeMinutes * (ringing.snoozesRemaining - 1),
      ),
    );
    String clock(DateTime value) =>
        '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
    return ringing.snoozesRemaining == 1
        ? 'Если перенести сейчас, последний звонок — в ${clock(next)}.'
        : 'Если перенести сейчас — ${clock(next)}. '
              'Если дальше по ${ringing.alarm.snoozeMinutes} мин — до ${clock(last)}.';
  }
}
