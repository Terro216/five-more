import 'package:flutter/material.dart';

import '../../app/alarm_controller.dart';
import '../../app/theme.dart';
import '../../models/alarm.dart';
import '../../models/wake_preset.dart';
import '../challenges/challenge_models.dart';
import '../challenges/challenge_screen.dart';

class AlarmEditor extends StatefulWidget {
  const AlarmEditor({super.key, required this.controller, this.alarm});
  final AlarmController controller;
  final Alarm? alarm;

  @override
  State<AlarmEditor> createState() => _AlarmEditorState();
}

class _AlarmEditorState extends State<AlarmEditor> {
  late Alarm _draft;
  late final TextEditingController _title;
  bool _saving = false;
  int _practiceSnoozes = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _draft = widget.alarm ?? Alarm.fresh();
    _title = TextEditingController(text: _draft.title);
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _draft.hour, minute: _draft.minute),
      initialEntryMode: TimePickerEntryMode.input,
      helpText: 'Во сколько встаём?',
      cancelText: 'Отмена',
      confirmText: 'Готово',
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked != null && mounted) {
      setState(
        () =>
            _draft = _draft.copyWith(hour: picked.hour, minute: picked.minute),
      );
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await widget.controller.saveAlarm(
      _draft.copyWith(
        title: _title.text == _draft.title ? _draft.title : _title.text.trim(),
        enabled: widget.alarm?.enabled ?? true,
      ),
    );
    if (!mounted) return;
    if (result.ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = result.error;
      });
    }
  }

  void _practice() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ChallengeScreen(
          kind: _draft.challengeKind,
          difficulty: _draft.difficultyForSnoozes(_practiceSnoozes),
          practice: true,
          onComplete: () => Navigator.of(context).pop(),
          onEmergencyExit: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.alarm == null ? 'Новый будильник' : 'Настроить подъём',
      ),
    ),
    bottomNavigationBar: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null)
              Semantics(
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _error!,
                    key: const ValueKey('alarm-save-error'),
                    style: const TextStyle(
                      color: Color(0xFFFFB4AB),
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            FilledButton(
              key: const ValueKey('save-alarm'),
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      widget.controller.device.supported
                          ? 'Сохранить будильник'
                          : 'Сохранить черновик',
                      textAlign: TextAlign.center,
                    ),
            ),
          ],
        ),
      ),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 24),
          children: [
            if (!widget.controller.device.supported)
              const _Note(
                icon: Icons.info_outline_rounded,
                text: 'Режим знакомства: настройки сохранятся, но будильник не зазвонит.',
              ),
            Semantics(
              button: true,
              enabled: !_saving,
              label: 'Время подъёма ${_draft.timeLabel}. Изменить время',
              excludeSemantics: true,
              onTap: _saving ? null : _pickTime,
              child: InkWell(
                onTap: _saving ? null : _pickTime,
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: 18,
                  ),
                  decoration: BoxDecoration(
                    color: panel,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                _draft.timeLabel,
                                style: const TextStyle(
                                  fontSize: 52,
                                  height: 1.15,
                                  fontWeight: FontWeight.w400,
                                  letterSpacing: -1,
                                  color: morning,
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Изменить время',
                              style: TextStyle(color: muted),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.edit_outlined, color: morning),
                    ],
                  ),
                ),
              ),
            ),
            const _Heading('Когда повторять'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _preset('Один раз', const []),
                _preset('Будни', const [1, 2, 3, 4, 5]),
                _preset('Каждый день', const [1, 2, 3, 4, 5, 6, 7]),
              ],
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 348 ? 7 : 4;
                final gap = columns == 7 ? 2.0 : 6.0;
                return Wrap(
                  spacing: gap,
                  runSpacing: 6,
                  children: List.generate(7, (index) {
                    final selected = _draft.weekdays.contains(index + 1);
                    return SizedBox(
                      width:
                          ((constraints.maxWidth - gap * (columns - 1)) /
                                  columns)
                              .clamp(48.0, 80.0),
                      child: Semantics(
                        label: '${shortWeekdays[index]}, повторять',
                        button: true,
                        enabled: !_saving,
                        selected: selected,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: _saving
                              ? null
                              : () {
                                  final days = [..._draft.weekdays];
                                  selected
                                      ? days.remove(index + 1)
                                      : days.add(index + 1);
                                  days.sort();
                                  setState(
                                    () => _draft = _draft.copyWith(
                                      weekdays: days,
                                    ),
                                  );
                                },
                          child: Container(
                            height: 48,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: selected ? morning : panel,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Text(
                              shortWeekdays[index],
                              style: TextStyle(
                                color: selected ? ink : muted,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                );
              },
            ),
            const _Heading('Как просыпаться'),
            ...WakePreset.values.map(_wakePreset),
            const SizedBox(height: 12),
            Text(
              WakePreset.matching(_draft) == null
                  ? 'Свои настройки'
                  : 'Выбрано: ${WakePreset.matching(_draft)!.label}',
              key: const ValueKey('wake-preset-summary'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (WakePreset.matching(_draft) == null) ...[
              const SizedBox(height: 4),
              Text(
                _activeSummary(),
                key: const ValueKey('wake-configuration-summary'),
                style: const TextStyle(color: muted, height: 1.4),
              ),
            ],
            const SizedBox(height: 12),
            ExpansionTile(
              key: const ValueKey('alarm-advanced'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 16),
              shape: const Border(),
              collapsedShape: const Border(),
              title: const Text('Настроить вручную'),
              subtitle: const Text('Переносы, задание и название'),
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _Heading('Ещё пять — сколько раз?'),
                    const Text(
                      'Лимит общий для одного подъёма: закрытие приложения его не сбросит.',
                      style: TextStyle(color: muted, height: 1.5),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [0, 1, 3]
                          .map(
                            (count) => ChoiceChip(
                              label: Text(
                                count == 0
                                    ? 'Без переносов'
                                    : count == 1
                                    ? '1 перенос'
                                    : '3 переноса',
                              ),
                              selected: _draft.maxSnoozes == count,
                              onSelected: _saving
                                  ? null
                                  : (_) => setState(
                                      () => _updateDraft(
                                        _draft.copyWith(maxSnoozes: count),
                                      ),
                                    ),
                            ),
                          )
                          .toList(),
                    ),
                    if (_draft.maxSnoozes > 0) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 10,
                        children: [
                          const Text(
                            'Каждый на',
                            style: TextStyle(color: muted),
                          ),
                          ...[5, 10].map(
                            (minutes) => ChoiceChip(
                              label: Text('$minutes минут'),
                              selected: _draft.snoozeMinutes == minutes,
                              onSelected: _saving
                                  ? null
                                  : (_) => setState(
                                      () => _draft = _draft.copyWith(
                                        snoozeMinutes: minutes,
                                      ),
                                    ),
                            ),
                          ),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          'Бюджет переносов: ${_draft.maxSnoozes * _draft.snoozeMinutes} мин. '
                          'Если нажимать сразу, последний звонок — в ${_lastRingLabel()}. '
                          'Если отвечать позже, он тоже сдвинется.',
                          style: const TextStyle(
                            color: morning,
                            fontSize: 12,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                    const _Heading('Задание для пробуждения'),
                    ...ChallengeKind.values.map(
                      (kind) => Semantics(
                        key: ValueKey('challenge-kind-${kind.name}'),
                        button: true,
                        selected: _draft.challengeKind == kind,
                        enabled: !_saving,
                        label: '${kind.label}. ${kind.description}',
                        excludeSemantics: true,
                        onTap: _saving
                            ? null
                            : () => setState(
                                () => _updateDraft(
                                  _draft.copyWith(challengeKind: kind),
                                ),
                              ),
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(challengeIcon(kind), color: muted),
                          title: Text(kind.label),
                          subtitle: Text(
                            kind.description,
                            style: const TextStyle(color: muted, height: 1.4),
                          ),
                          trailing: Icon(
                            _draft.challengeKind == kind
                                ? Icons.radio_button_checked_rounded
                                : Icons.radio_button_unchecked_rounded,
                            color: _draft.challengeKind == kind
                                ? morning
                                : muted,
                          ),
                          onTap: _saving
                              ? null
                              : () => setState(
                                  () => _updateDraft(
                                    _draft.copyWith(challengeKind: kind),
                                  ),
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: ChallengeDifficulty.values
                          .map(
                            (level) => ChoiceChip(
                              label: Text(level.label),
                              selected: _draft.difficulty == level,
                              onSelected: _saving
                                  ? null
                                  : (_) => setState(
                                      () => _updateDraft(
                                        _draft.copyWith(difficulty: level),
                                      ),
                                    ),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 10),
                    SwitchListTile.adaptive(
                      key: const ValueKey('escalate-on-snooze'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Сложнее после переноса'),
                      subtitle: Text(
                        _draft.maxSnoozes == 0 ? 'Сейчас переносы выключены.' : 'Каждый перенос поднимает уровень, максимум — «Сложно».',
                        style: const TextStyle(
                          color: muted,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                      value: _draft.escalateOnSnooze,
                      onChanged: _saving || _draft.maxSnoozes == 0
                          ? null
                          : (value) => setState(
                              () => _updateDraft(
                                _draft.copyWith(escalateOnSnooze: value),
                              ),
                            ),
                    ),
                    if (_draft.escalateOnSnooze && _draft.maxSnoozes > 0) ...[
                      const SizedBox(height: 4),
                      Text(
                        _difficultyPlan(),
                        key: const ValueKey('escalation-plan'),
                        style: const TextStyle(
                          color: morning,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                      if (_practiceStages.length > 1) ...[
                        const SizedBox(height: 18),
                        DropdownButtonFormField<int>(
                          key: ValueKey('practice-stage-$_practiceSnoozes'),
                          initialValue: _practiceSnoozes,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Какой звонок попробовать',
                          ),
                          items: _practiceStages
                              .map(
                                (used) => DropdownMenuItem(
                                  value: used,
                                  child: Text(
                                    '${_stageLabel(used)} · ${_draft.difficultyForSnoozes(used).label}',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: _saving
                              ? null
                              : (value) => setState(
                                  () => _practiceSnoozes = value ?? 0,
                                ),
                        ),
                      ],
                    ],
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const ValueKey('practice-alarm'),
                        onPressed: _saving ? null : _practice,
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('Попробовать задание'),
                      ),
                    ),
                    const _Heading('Название · необязательно'),
                    TextField(
                      key: const ValueKey('alarm-title'),
                      controller: _title,
                      maxLength: 50,
                      enabled: !_saving,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        hintText: 'Например, утренняя прогулка',
                        counterText: '',
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (!widget.controller.device.challengeEnforced)
              const _Note(
                icon: Icons.phone_iphone_rounded,
                text:
                    'На iPhone системный будильник можно остановить без задания. '
                    'Задания доступны после открытия приложения.',
              ),
          ],
        ),
      ),
    ),
  );

  Widget _wakePreset(WakePreset preset) {
    final selected = preset.matches(_draft);
    void choose() => setState(() => _updateDraft(preset.applyTo(_draft)));
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Semantics(
        key: ValueKey('preset-${preset.name}'),
        button: true,
        selected: selected,
        enabled: !_saving,
        label: '${preset.label}. ${preset.description}',
        excludeSemantics: true,
        onTap: _saving ? null : choose,
        child: Material(
          color: selected ? panel : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: ListTile(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            minVerticalPadding: 8,
            leading: Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: selected ? morning : muted,
            ),
            title: Text(
              preset.label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              preset.description,
              style: const TextStyle(color: muted, height: 1.4),
            ),
            onTap: _saving ? null : choose,
          ),
        ),
      ),
    );
  }

  String _activeSummary() {
    final snoozes = _draft.maxSnoozes == 0
        ? 'Без переносов'
        : '${_draft.maxSnoozes} × ${_draft.snoozeMinutes} мин';
    final escalation = _draft.escalateOnSnooze && _draft.maxSnoozes > 0
        ? ' · сложнее после переноса'
        : '';
    return '${_draft.challengeKind.label} · ${_draft.difficulty.label.toLowerCase()} · $snoozes$escalation';
  }

  void _updateDraft(Alarm value) {
    _draft = value;
    if (!_practiceStages.contains(_practiceSnoozes)) _practiceSnoozes = 0;
  }

  List<int> get _practiceStages {
    final stages = [0];
    if (!_draft.escalateOnSnooze) return stages;
    for (var used = 1; used <= _draft.maxSnoozes; used++) {
      if (_draft.difficultyForSnoozes(used) !=
          _draft.difficultyForSnoozes(stages.last)) {
        stages.add(used);
      }
    }
    return stages;
  }

  String _stageLabel(int used) => used == 0
      ? 'Первый звонок'
      : used == 1
      ? 'После 1 переноса'
      : 'После $used переносов';

  String _difficultyPlan() {
    final stages = _practiceStages;
    final plan = stages
        .map((used) {
          final label = used == 0
              ? _stageLabel(used)
              : _stageLabel(used).toLowerCase();
          return '$label: ${_draft.difficultyForSnoozes(used).label}';
        })
        .join(' · ');
    return stages.last < _draft.maxSnoozes
        ? '$plan. Дальше сложность не растёт.'
        : '$plan.';
  }

  String _lastRingLabel() {
    final total =
        _draft.hour * 60 +
        _draft.minute +
        _draft.maxSnoozes * _draft.snoozeMinutes;
    final hour = (total ~/ 60) % 24;
    final minute = total % 60;
    final clock =
        '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
    return total >= 24 * 60 ? '$clock следующего дня' : clock;
  }

  Widget _preset(String label, List<int> days) => ChoiceChip(
    label: Text(label),
    selected:
        _draft.weekdays.length == days.length &&
        days.every(_draft.weekdays.contains),
    onSelected: _saving
        ? null
        : (_) => setState(() => _draft = _draft.copyWith(weekdays: days)),
  );
}

IconData challengeIcon(ChallengeKind kind) => switch (kind) {
  ChallengeKind.math => Icons.calculate_outlined,
  ChallengeKind.memory => Icons.grid_view_rounded,
  ChallengeKind.stroop => Icons.palette_outlined,
  ChallengeKind.sequence => Icons.format_list_numbered_rounded,
  ChallengeKind.mixed => Icons.shuffle_rounded,
};

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 22, bottom: 10),
    child: Text(
      text,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: morning.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: morning),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 13, height: 1.5)),
        ),
      ],
    ),
  );
}
