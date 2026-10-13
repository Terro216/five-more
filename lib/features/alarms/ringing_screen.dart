import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/alarm_controller.dart';
import '../../app/theme.dart';
import '../../models/alarm.dart';
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
  String? _error;

  @override
  void dispose() {
    _holdTimer?.cancel();
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
            kind: ringing.alarm.challengeKind,
            difficulty: ringing.alarm.difficulty,
            onComplete: () => _dismiss(),
            onEmergencyExit: () => _dismiss(emergency: true),
          );
        }
        if (_emergency) return _emergencyScreen();
        return Scaffold(
          backgroundColor: ink,
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(26, 26, 26, 18),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.wb_twilight_rounded,
                              color: morning,
                              size: 64,
                            ),
                            const SizedBox(height: 22),
                            Text(
                              ringing.alarm.id.startsWith('preview:')
                                  ? 'ПРОВЕРКА БУДИЛЬНИКА'
                                  : 'ДОБРОЕ УТРО',
                              style: const TextStyle(
                                color: morning,
                                fontSize: 11,
                                letterSpacing: 2.4,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 16),
                            FittedBox(
                              child: Text(
                                ringing.alarm.timeLabel,
                                style: const TextStyle(
                                  fontSize: 92,
                                  fontWeight: FontWeight.w300,
                                  letterSpacing: -5,
                                  height: 1.1,
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              ringing.alarm.displayTitle,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 23,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 38),
                            Container(
                              padding: const EdgeInsets.all(18),
                              decoration: BoxDecoration(
                                color: panel,
                                borderRadius: BorderRadius.circular(22),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    challengeIcon(ringing.alarm.challengeKind),
                                    color: morning,
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          ringing.alarm.challengeKind.label,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '${ringing.alarm.difficulty.label} · пройди, чтобы отключить',
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: muted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),
                            if (_error != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Text(
                                  _error!,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.redAccent,
                                  ),
                                ),
                              ),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                onPressed: _finishing || widget.controller.busy
                                    ? null
                                    : () => setState(() => _challenge = true),
                                icon: const Icon(Icons.arrow_forward_rounded),
                                label: const Text('Я встаю · пройти задание'),
                              ),
                            ),
                            const SizedBox(height: 12),
                            if (ringing.snoozesRemaining > 0) ...[
                              SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  onPressed:
                                      _finishing || widget.controller.busy
                                      ? null
                                      : _snooze,
                                  icon: const Icon(Icons.snooze_rounded),
                                  label: Text(
                                    'Ещё ${ringing.alarm.snoozeMinutes} минут',
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                'Осталось переносов: ${ringing.snoozesRemaining} из ${ringing.alarm.maxSnoozes}',
                                style: const TextStyle(
                                  color: muted,
                                  fontSize: 12,
                                ),
                              ),
                            ] else
                              const Text(
                                'Переносов больше нет. Осталось разбудить голову.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: muted,
                                  fontSize: 13,
                                  height: 1.5,
                                ),
                              ),
                            const SizedBox(height: 26),
                            TextButton(
                              onPressed: _finishing
                                  ? null
                                  : () => setState(() => _emergency = true),
                              child: const Text(
                                'Аварийное отключение',
                                style: TextStyle(color: muted, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );

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
