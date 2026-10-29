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
      _chosenMinutes = ringing.defaultSnoozeMinutes;
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
                  'Проблема с заданием',
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
                    final compact =
                        _snoozeEditing ||
                        constraints.maxHeight < 680 ||
                        MediaQuery.textScalerOf(context).scale(14) > 18;
                    final summary = ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: _error == null ? double.infinity : 120,
                      ),
                      child: SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(
                          24,
                          compact ? 8 : 20,
                          24,
                          compact ? 8 : 16,
                        ),
                        child: _error == null
                            ? _ringSummary(ringing, compact: compact)
                            : Semantics(
                                liveRegion: true,
                                child: Text(
                                  _error!,
                                  key: const ValueKey('ringing-error'),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                              ),
                      ),
                    );
                    final actions = Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                      child: _ringActions(ringing),
                    );
                    if (_snoozeEditing) {
                      return SingleChildScrollView(
                        child: Column(children: [summary, actions]),
                      );
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

  Widget _ringSummary(RingingAlarm ringing, {required bool compact}) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (!compact || ringing.alarm.id.startsWith('preview:')) ...[
        if (!compact)
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
      ],
      FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          clockLabel(TimeOfDay.fromDateTime(widget.controller.now)),
          style: TextStyle(
            fontSize: compact ? 72 : 96,
            fontWeight: FontWeight.w300,
            letterSpacing: -2,
            height: 1.1,
          ),
        ),
      ),
      if (!_snoozeEditing) ...[
        SizedBox(height: compact ? 6 : 12),
        Text(
          ringing.alarm.displayTitle,
          textAlign: TextAlign.center,
          maxLines: compact ? 1 : null,
          overflow: compact ? TextOverflow.ellipsis : null,
          style: TextStyle(
            fontSize: compact ? 18 : 22,
            fontWeight: FontWeight.w600,
          ),
        ),
        SizedBox(height: compact ? 12 : 24),
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
      ],
      const SizedBox(height: 6),
      Text(
        _challengeLevel(ringing),
        key: const ValueKey('ringing-challenge-level'),
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 14, color: muted),
      ),
      if (!_snoozeEditing) ...[
        SizedBox(height: compact ? 10 : 20),
        Text(
          ringing.minutesRemaining > 0
              ? 'На переносы осталось ${ringing.minutesRemaining} мин'
              : 'Запас минут закончился',
          textAlign: TextAlign.center,
          style: const TextStyle(color: muted, fontSize: 14),
        ),
      ],
      if (ringing.minutesRemaining > 0 &&
          ringing.alarm.escalateOnSnooze &&
          ringing.alarm.difficultyForSnoozes(ringing.snoozesUsed + 1) !=
              ringing.challengeDifficulty) ...[
        const SizedBox(height: 8),
        Text(
          'После переноса сложность: ${ringing.alarm.difficultyForSnoozes(ringing.snoozesUsed + 1).label}',
          textAlign: TextAlign.center,
          style: const TextStyle(color: muted, fontSize: 14),
        ),
      ],
    ],
  );

  Widget _ringActions(RingingAlarm ringing) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
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
      if (ringing.minutesRemaining > 0) ...[
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
              max: ringing.minutesRemaining.clamp(2, 30).toDouble(),
              divisions: ringing.minutesRemaining.clamp(2, 30) - 1,
              label: '$_chosenMinutes мин',
              onChanged: _finishing || ringing.minutesRemaining == 1
                  ? null
                  : (v) => setState(() => _chosenMinutes = v.round()),
            ),
            Text(
              'Останется ${ringing.minutesRemaining - _chosenMinutes} мин на переносы',
              textAlign: TextAlign.center,
              style: const TextStyle(color: muted, fontSize: 12),
            ),
            const SizedBox(height: 16),
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
    final target = snoozeTileFor(ringing.occurrenceId, ringing.snoozesUsed);
    const labels = ['УТРО', 'ПОРА', 'СОН', 'ДЕНЬ', 'ПЯТЬ'];
    return Column(
      key: const ValueKey('moving-snooze-area'),
      children: [
        const SizedBox(height: 6),
        const Text(
          'Найди «ЕЩЁ» · удерживай для выбора минут',
          textAlign: TextAlign.center,
          style: TextStyle(color: muted, fontSize: 12),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) => Wrap(
            spacing: 8,
            runSpacing: 8,
            children: List.generate(6, (index) {
              final correct = index == target;
              return SizedBox(
                width: (constraints.maxWidth - 16) / 3,
                child: OutlinedButton(
                  key: ValueKey(
                    correct ? 'ringing-snooze' : 'snooze-decoy-$index',
                  ),
                  onPressed: onPressed == null
                      ? null
                      : correct
                      ? onPressed
                      : () {},
                  onLongPress: correct && onPressed != null
                      ? () => _editSnooze(ringing)
                      : null,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    textStyle: const TextStyle(
                      fontSize: 14,
                      height: 1.1,
                      fontWeight: FontWeight.w600,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 12,
                    ),
                  ),
                  child: Text(
                    correct
                        ? 'ЕЩЁ'
                        : labels[index < target ? index : index - 1],
                    maxLines: 1,
                    softWrap: false,
                    semanticsLabel: correct
                        ? 'ЕЩЁ. Перенести на ${ringing.defaultSnoozeMinutes} мин. Удерживай для выбора минут.'
                        : labels[index < target ? index : index - 1],
                  ),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }

  String _challengeLevel(RingingAlarm ringing) =>
      'Сложность: ${ringing.challengeDifficulty.label}';

  String _snoozeLabel(RingingAlarm ringing) =>
      'Ещё ${ringing.defaultSnoozeMinutes} мин';
}
