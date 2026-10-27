import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../models/alarm.dart';
import '../../models/sleep_entry.dart';
import '../../services/sleep_journal.dart';
import '../../widgets/time_composer.dart';

class SleepReview extends StatefulWidget {
  const SleepReview({super.key, required this.journal, required this.event});
  final SleepJournal journal;
  final AlarmEvent event;
  @override
  State<SleepReview> createState() => _SleepReviewState();
}

class _SleepReviewState extends State<SleepReview> {
  int _sleep = 3, _wake = 3;
  bool _saving = false;
  late TimeOfDay _bed = TimeOfDay(
    hour: widget.journal.bedHour,
    minute: widget.journal.bedMinute,
  );
  String? _error;
  DateTime get _bedAt {
    final wake = widget.event.at;
    var value = DateTime(
      wake.year,
      wake.month,
      wake.day,
      _bed.hour,
      _bed.minute,
    );
    if (!value.isBefore(wake)) {
      value = DateTime(
        wake.year,
        wake.month,
        wake.day - 1,
        _bed.hour,
        _bed.minute,
      );
    }
    return value;
  }

  Widget _rating(String title, int value, ValueChanged<int> change) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      Wrap(
        spacing: 6,
        children: List.generate(
          5,
          (i) => ChoiceChip(
            label: Text('${i + 1}'),
            selected: value == i + 1,
            onSelected: _saving ? null : (_) => change(i + 1),
          ),
        ),
      ),
      const Text(
        '1 — тяжело · 5 — отлично',
        style: TextStyle(color: muted, fontSize: 12),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Как спалось?')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        _rating('Качество сна', _sleep, (v) => setState(() => _sleep = v)),
        const SizedBox(height: 24),
        _rating('Как дался подъём', _wake, (v) => setState(() => _wake = v)),
        const SizedBox(height: 24),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Во сколько лёг / легла?'),
          subtitle: Text('По твоим воспоминаниям · ${clockLabel(_bed)}'),
          trailing: const Icon(Icons.edit_outlined),
          onTap: _saving
              ? null
              : () async {
                  final value = await editClock(
                    context,
                    _bed,
                    title: 'Когда лёг / легла',
                  );
                  if (value != null && mounted) setState(() => _bed = value);
                },
        ),
        Text(
          'В постели до отключения будильника: ${remainingLabel(widget.event.at, _bedAt)}',
          style: const TextStyle(color: morning),
        ),
        const SizedBox(height: 16),
        const Text(
          'Это оценка времени в постели. Приложение не измеряет момент засыпания и ночные пробуждения.',
          style: TextStyle(color: muted, height: 1.5),
        ),
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
                  setState(() => _saving = true);
                  try {
                    await widget.journal.saveEntry(
                      SleepEntry(
                        occurrenceId: widget.event.occurrenceId,
                        wokeAt: widget.event.at,
                        bedAt: _bedAt,
                        sleepQuality: _sleep,
                        wakeQuality: _wake,
                      ),
                    );
                    if (context.mounted) Navigator.pop(context);
                  } catch (_) {
                    if (mounted) {
                      setState(() {
                        _saving = false;
                        _error =
                            'Не удалось сохранить оценку. Попробуй ещё раз.';
                      });
                    }
                  }
                },
          child: const Text('Сохранить оценку'),
        ),
      ],
    ),
  );
}
