import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/alarm_controller.dart';
import '../../app/theme.dart';
import '../../l10n/strings.dart';
import '../../models/alarm.dart';
import '../../models/snooze_position.dart';
import '../../widgets/alarm_background.dart';
import '../../widgets/emergency_stop.dart';
import '../../widgets/time_composer.dart';
import '../challenges/challenge_models.dart';
import '../challenges/challenge_screen.dart';
import 'alarm_editor.dart';

class RingingScreen extends StatefulWidget {
  const RingingScreen({
    super.key,
    required this.controller,
    required this.ringing,
    this.allowBack = false,
    this.disableAlarm = false,
  });
  final AlarmController controller;
  final RingingAlarm ringing;
  final bool allowBack;
  final bool disableAlarm;

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
      generation: widget.ringing.snoozesUsed,
      disableAlarm: widget.disableAlarm,
    );
    if (mounted && result.ok && widget.allowBack) {
      Navigator.of(context).pop();
      return;
    }
    if (mounted && !result.ok) {
      setState(() {
        _finishing = false;
        _challenge = false;
        _emergency = false;
        _error = result.error ?? appStrings.couldntDismissTheAlarmTryAgain;
      });
    }
  }

  Widget? _quietButton(RingingAlarm ringing) {
    if (ringing.isSnoozed) return null;
    if (widget.controller.device.platform != 'android') return null;
    final remaining = ringing.quietRemainingSeconds;
    final exhausted = ringing.quietUsed >= 2;
    return TextButton(
      key: const ValueKey('quiet-alarm'),
      onPressed:
          _finishing || widget.controller.busy || remaining > 0 || exhausted
          ? null
          : () async {
              final result = await widget.controller.quiet(ringing);
              if (mounted && !result.ok) {
                final message =
                    result.error ?? appStrings.couldntLowerTheVolume;
                setState(() => _error = message);
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(message)));
              }
            },
      child: Text(
        remaining > 0
            ? appStrings.quieterS(remaining)
            : exhausted
            ? appStrings.quietLimitReached
            : appStrings.quieter30S,
        style: const TextStyle(fontSize: 14),
      ),
    );
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
    canPop: widget.allowBack,
    child: AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final active = widget.controller.activeOccurrence(
          widget.ringing.alarm.id,
        );
        final ringing = active?.occurrenceId == widget.ringing.occurrenceId
            ? active!
            : widget.ringing;
        if (widget.allowBack &&
            !_finishing &&
            (active?.occurrenceId != widget.ringing.occurrenceId ||
                active?.snoozesUsed != widget.ringing.snoozesUsed)) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error ??
                      (active == null
                          ? context.strings.thisAlarmHasAlreadyEnded
                          : context.strings.alarmChangedReopenHint),
                ),
              ),
            ),
          );
        }
        if (_challenge) {
          return ChallengeScreen(
            key: ValueKey(
              '${ringing.occurrenceId}:${ringing.challengeDifficulty.name}',
            ),
            kind: ringing.alarm.challengeKind,
            difficulty: ringing.challengeDifficulty,
            order: ringing.alarm.mixOrder,
            qrValue: ringing.alarm.qrValue,
            alarmAction: _quietButton(ringing),
            progressIdentity: '${ringing.occurrenceId}:${ringing.snoozesUsed}',
            onComplete: () {
              _completedOccurrenceId = ringing.occurrenceId;
              _dismiss();
            },
            onEmergencyExit: () => _dismiss(emergency: true),
          );
        }
        return AlarmBackground(
          name: ringing.alarm.background,
          frame: ringing.alarm.backgroundFrame,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            appBar:
                widget.allowBack ||
                    widget.controller.device.platform == 'android'
                ? AppBar(
                    backgroundColor: Colors.transparent,
                    automaticallyImplyLeading: widget.allowBack,
                    title: Align(
                      alignment: Alignment.centerRight,
                      child: _quietButton(ringing) ?? const SizedBox.shrink(),
                    ),
                  )
                : null,
            resizeToAvoidBottomInset: false,
            bottomNavigationBar: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: TextButton(
                  key: const ValueKey('ringing-emergency'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _finishing ? null : _emergencyStop,
                  child: Text(
                    ringing.alarm.requiresChallenge
                        ? context.strings.troubleWithTheChallenge
                        : context.strings.emergencyDismissal,
                    style: TextStyle(color: context.palette.muted),
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
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error,
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
          Icon(
            Icons.wb_twilight_rounded,
            color: context.palette.morning,
            size: 36,
          ),
        const SizedBox(height: 12),
        Text(
          ringing.alarm.id.startsWith('preview:')
              ? appStrings.alarmTest
              : appStrings.goodMorning,
          textAlign: TextAlign.center,
          style: TextStyle(color: context.palette.morning, fontSize: 16),
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
      if (ringing.isSnoozed) ...[
        const SizedBox(height: 12),
        Text(
          appStrings.snoozedUntil(
            clockLabel(TimeOfDay.fromDateTime(ringing.snoozedUntil!)),
          ),
          key: const ValueKey('snoozed-until'),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          widget.disableAlarm
              ? appStrings.finishThisWakeUpToTurnOff
              : appStrings.youCanDismissTheAlarmNow,
          textAlign: TextAlign.center,
        ),
      ],
      if (!_snoozeEditing) ...[
        SizedBox(height: compact ? 6 : 12),
        if (ringing.alarm.displayTitle.isNotEmpty)
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
        if (ringing.alarm.requiresChallenge)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                challengeIcon(ringing.alarm.challengeKind),
                color: context.palette.morning,
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
      if (ringing.alarm.requiresChallenge)
        Text(
          _challengeLevel(ringing),
          key: const ValueKey('ringing-challenge-level'),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: context.palette.muted),
        ),
      if (!_snoozeEditing) ...[
        SizedBox(height: compact ? 10 : 20),
        Text(
          ringing.minutesRemaining > 0
              ? appStrings.minOfSnoozeTimeLeft(ringing.minutesRemaining)
              : appStrings.noSnoozeTimeLeftLabel,
          textAlign: TextAlign.center,
          style: TextStyle(color: context.palette.muted, fontSize: 14),
        ),
      ],
      if (ringing.alarm.requiresChallenge &&
          ringing.minutesRemaining > 0 &&
          ringing.alarm.escalateOnSnooze &&
          ringing.alarm.difficultyForSnoozes(ringing.snoozesUsed + 1) !=
              ringing.challengeDifficulty) ...[
        const SizedBox(height: 8),
        Text(
          appStrings.difficultyAfterSnooze(
            ringing.alarm.difficultyForSnoozes(ringing.snoozesUsed + 1).label,
          ),
          textAlign: TextAlign.center,
          style: TextStyle(color: context.palette.muted, fontSize: 14),
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
            : !ringing.alarm.requiresChallenge ||
                  _completedOccurrenceId == ringing.occurrenceId
            ? () => _dismiss()
            : () => setState(() => _challenge = true),
        icon: const Icon(Icons.arrow_forward_rounded),
        label: Text(
          !ringing.alarm.requiresChallenge
              ? widget.disableAlarm
                    ? appStrings.dismissAndTurnOff
                    : ringing.isSnoozed
                    ? appStrings.dismissAlarm
                    : appStrings.dismiss
              : _completedOccurrenceId == ringing.occurrenceId
              ? appStrings.tryDismissingAgain
              : appStrings.startChallenge,
          textAlign: TextAlign.center,
        ),
      ),
      if (!ringing.isSnoozed && ringing.minutesRemaining > 0) ...[
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
          color: context.palette.panel,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            Text(
              appStrings.snoozeMinRingsAt(
                _chosenMinutes,
                clockLabel(TimeOfDay.fromDateTime(next)),
              ),
              textAlign: TextAlign.center,
              style: TextStyle(color: context.palette.morning),
            ),
            Slider(
              value: _chosenMinutes.toDouble(),
              min: 1,
              max: ringing.minutesRemaining.clamp(2, 30).toDouble(),
              divisions: ringing.minutesRemaining.clamp(2, 30) - 1,
              label: appStrings.minutesShort(_chosenMinutes),
              onChanged: _finishing || ringing.minutesRemaining == 1
                  ? null
                  : (v) => setState(() => _chosenMinutes = v.round()),
            ),
            Text(
              appStrings.minOfSnoozeTimeWillRemain(
                ringing.minutesRemaining - _chosenMinutes,
              ),
              textAlign: TextAlign.center,
              style: TextStyle(color: context.palette.muted, fontSize: 12),
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
                  child: Text(appStrings.cancel),
                ),
                FilledButton(
                  onPressed: _finishing ? null : _snooze,
                  child: Text(appStrings.snoozeForMin(_chosenMinutes)),
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
    final labels = [
      appStrings.dawn,
      appStrings.rise,
      appStrings.rest,
      appStrings.noon,
      appStrings.five,
    ];
    return Column(
      key: const ValueKey('moving-snooze-area'),
      children: [
        const SizedBox(height: 6),
        Text(
          appStrings.findMoreHoldToChooseSnoozeTime,
          textAlign: TextAlign.center,
          style: TextStyle(color: context.palette.muted, fontSize: 12),
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
                        ? context.strings.more
                        : labels[index < target ? index : index - 1],
                    maxLines: 1,
                    softWrap: false,
                    semanticsLabel: correct
                        ? context.strings.movingSnoozeHint(
                            ringing.defaultSnoozeMinutes,
                          )
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
      appStrings.difficulty(ringing.challengeDifficulty.label);

  String _snoozeLabel(RingingAlarm ringing) => ringing.alarm.requiresChallenge
      ? appStrings.snoozeMin(ringing.defaultSnoozeMinutes)
      : appStrings.snoozeForMin(ringing.defaultSnoozeMinutes);
}
