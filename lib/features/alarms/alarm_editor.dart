import 'package:flutter/material.dart';

import '../../app/alarm_controller.dart';
import '../../app/theme.dart';
import '../../models/alarm.dart';
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
        title: _title.text.trim(),
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
          difficulty: _draft.difficulty,
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
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: FilledButton(
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
                ),
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
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: _Note(
                  icon: Icons.error_outline,
                  text: _error!,
                  error: true,
                ),
              ),
            Semantics(
              button: true,
              label: 'Время подъёма ${_draft.timeLabel}',
              child: InkWell(
                onTap: _saving ? null : _pickTime,
                borderRadius: BorderRadius.circular(26),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 18,
                    horizontal: 24,
                  ),
                  decoration: BoxDecoration(
                    color: panel,
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: Column(
                    children: [
                      const Text(
                        'ВРЕМЯ ПОДЪЁМА',
                        style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 2,
                          color: muted,
                        ),
                      ),
                      FittedBox(
                        child: Text(
                          _draft.timeLabel,
                          style: const TextStyle(
                            fontSize: 76,
                            height: 1.3,
                            fontWeight: FontWeight.w300,
                            letterSpacing: -3,
                            color: morning,
                          ),
                        ),
                      ),
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.edit_outlined, size: 14, color: muted),
                          SizedBox(width: 6),
                          Text(
                            'Изменить время',
                            style: TextStyle(color: muted, fontSize: 12),
                          ),
                        ],
                      ),
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
              builder: (context, constraints) => Wrap(
                spacing: 6,
                runSpacing: 6,
                children: List.generate(7, (index) {
                  final selected = _draft.weekdays.contains(index + 1);
                  return SizedBox(
                    width: (constraints.maxWidth - 36) / 7,
                    child: Semantics(
                      label: shortWeekdays[index],
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
                                  () =>
                                      _draft = _draft.copyWith(weekdays: days),
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
              ),
            ),
            const _Heading('Ещё пять — сколько раз?'),
            const Text(
              'Лимит действует на один подъём. После него останется пройти задание.',
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
                              () => _draft = _draft.copyWith(maxSnoozes: count),
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
                  const Text('Каждый на', style: TextStyle(color: muted)),
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
                  'Всего до ${_draft.maxSnoozes * _draft.snoozeMinutes} минут отсрочки',
                  style: const TextStyle(color: morning, fontSize: 12),
                ),
              ),
            ],
            const _Heading('Задание для пробуждения'),
            ...ChallengeKind.values.map(
              (kind) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: InkWell(
                  onTap: _saving
                      ? null
                      : () => setState(
                          () => _draft = _draft.copyWith(challengeKind: kind),
                        ),
                  borderRadius: BorderRadius.circular(18),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: panel,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: _draft.challengeKind == kind
                            ? morning
                            : Colors.transparent,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          challengeIcon(kind),
                          color: _draft.challengeKind == kind ? morning : muted,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                kind.label,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                kind.description,
                                style: const TextStyle(
                                  color: muted,
                                  fontSize: 12,
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_draft.challengeKind == kind)
                          const Padding(
                            padding: EdgeInsets.only(left: 8),
                            child: Icon(
                              Icons.check_circle_rounded,
                              color: morning,
                              size: 20,
                            ),
                          ),
                      ],
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
                              () => _draft = _draft.copyWith(difficulty: level),
                            ),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _practice,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Попробовать задание'),
              ),
            ),
            if (!widget.controller.device.challengeEnforced)
              const _Note(
                icon: Icons.phone_iphone_rounded,
                text:
                    'На iPhone системный будильник можно остановить без задания. '
                    'Задания доступны после открытия приложения.',
              ),
            const _Heading('Название · необязательно'),
            TextField(
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
      ),
    ),
  );

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
  ChallengeKind.mixed => Icons.shuffle_rounded,
};

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 28, bottom: 12),
    child: Text(
      text,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text, this.error = false});
  final IconData icon;
  final String text;
  final bool error;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: (error ? Colors.red : morning).withValues(alpha: .08),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: error ? Colors.redAccent : morning),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 13, height: 1.5)),
        ),
      ],
    ),
  );
}
