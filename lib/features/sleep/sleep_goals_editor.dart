import 'package:flutter/material.dart';

import '../../models/sleep_goals.dart';
import '../../services/sleep_journal.dart';

class SleepGoalsEditor extends StatefulWidget {
  const SleepGoalsEditor({super.key, required this.journal});
  final SleepJournal journal;
  @override
  State<SleepGoalsEditor> createState() => _SleepGoalsEditorState();
}

class _SleepGoalsEditorState extends State<SleepGoalsEditor> {
  final _form = GlobalKey<FormState>();
  late bool _duration = widget.journal.goals.durationMinutes != null;
  late bool _schedule = widget.journal.goals.hasSchedule;
  late final _minutes = TextEditingController(
    text: widget.journal.goals.durationMinutes?.toString() ?? '',
  );
  late final _bed = TextEditingController(
    text: widget.journal.goals.bedMinute == null
        ? ''
        : SleepGoals.clock(widget.journal.goals.bedMinute!),
  );
  late final _wake = TextEditingController(
    text: widget.journal.goals.wakeMinute == null
        ? ''
        : SleepGoals.clock(widget.journal.goals.wakeMinute!),
  );
  late final _tolerance = TextEditingController(
    text: widget.journal.goals.toleranceMinutes?.toString() ?? '',
  );
  bool _saving = false;
  String? _error;
  int? _time(String value) {
    final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(value);
    if (match == null) return null;
    final hour = int.parse(match[1]!), minute = int.parse(match[2]!);
    return hour < 24 && minute < 60 ? hour * 60 + minute : null;
  }

  String? _integer(String? raw, int min, int max) {
    final number = int.tryParse(raw ?? '');
    return number != null && number >= min && number <= max
        ? null
        : 'Целое число от $min до $max';
  }

  @override
  void dispose() {
    for (final c in [_minutes, _bed, _wake, _tolerance]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Моя цель')),
    body: Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Выбери своё стремление. Оно хранится на этом телефоне и не меняет будильники.',
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Длительность сна'),
            value: _duration,
            onChanged: _saving ? null : (v) => setState(() => _duration = v),
          ),
          if (_duration)
            TextFormField(
              controller: _minutes,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Желаемая длительность',
                suffixText: 'мин',
              ),
              validator: (v) => _integer(v, 1, 1440),
            ),
          const SizedBox(height: 24),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Регулярный режим'),
            value: _schedule,
            onChanged: _saving ? null : (v) => setState(() => _schedule = v),
          ),
          if (_schedule) ...[
            TextFormField(
              controller: _bed,
              keyboardType: TextInputType.datetime,
              decoration: const InputDecoration(
                labelText: 'Укладываться в',
                hintText: 'ЧЧ:ММ',
              ),
              validator: (v) =>
                  _time(v ?? '') == null ? 'Время от 00:00 до 23:59' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _wake,
              keyboardType: TextInputType.datetime,
              decoration: const InputDecoration(
                labelText: 'Вставать в',
                hintText: 'ЧЧ:ММ',
              ),
              validator: (v) =>
                  _time(v ?? '') == null ? 'Время от 00:00 до 23:59' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _tolerance,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Допустимое отклонение',
                suffixText: 'мин',
              ),
              validator: (v) => _integer(v, 0, 720),
            ),
            const SizedBox(height: 16),
            const Text(
              'Сравниваем местное время. Укладывание оценивается по источнику времени сна; это не измерение.',
            ),
          ],
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _saving
                ? null
                : () async {
                    if (!_form.currentState!.validate()) return;
                    setState(() => _saving = true);
                    try {
                      await widget.journal.setGoals(
                        SleepGoals(
                          durationMinutes: _duration
                              ? int.parse(_minutes.text)
                              : null,
                          bedMinute: _schedule ? _time(_bed.text) : null,
                          wakeMinute: _schedule ? _time(_wake.text) : null,
                          toleranceMinutes: _schedule
                              ? int.parse(_tolerance.text)
                              : null,
                        ),
                      );
                      if (context.mounted) {
                        Navigator.pop(context);
                      }
                    } catch (_) {
                      if (mounted) {
                        setState(() {
                          _saving = false;
                          _error =
                              'Не удалось сохранить цель. Попробуй ещё раз.';
                        });
                      }
                    }
                  },
            child: const Text('Сохранить цель'),
          ),
        ],
      ),
    ),
  );
}
