import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../models/alarm.dart';
import '../../models/sleep_entry.dart';
import '../../models/sleep_session.dart';
import '../../services/sleep_journal.dart';
import '../../widgets/time_composer.dart';

class SleepReview extends StatefulWidget {
  const SleepReview({
    super.key,
    required this.journal,
    required this.event,
    this.session,
  });
  final SleepJournal journal;
  final AlarmEvent event;
  final SleepSession? session;
  @override
  State<SleepReview> createState() => _SleepReviewState();
}

class _SleepReviewState extends State<SleepReview> {
  int _sleep = 3, _wake = 3;
  bool _saving = false, _separate = false;
  bool _bedEdited = false, _wakeEdited = false;
  late DateTime _wakeAt = widget.event.at;
  late TimeOfDay _bed = widget.session?.bedtimeCandidate == null
      ? TimeOfDay(
          hour: widget.journal.bedHour,
          minute: widget.journal.bedMinute,
        )
      : TimeOfDay.fromDateTime(
          widget.session!.bedtimeCandidate!.add(
            Duration(minutes: widget.journal.fallingAsleepMinutes),
          ),
        );
  String? _error;
  @override
  void initState() {
    super.initState();
    final existing = widget.journal.entries
        .where(
          (e) =>
              e.occurrenceId ==
              (widget.session?.id ?? widget.event.occurrenceId),
        )
        .firstOrNull;
    if (existing != null) {
      _sleep = existing.sleepQuality;
      _wake = existing.wakeQuality;
      _bed = TimeOfDay.fromDateTime(existing.bedAt);
      _bedEdited = existing.bedSource == 'manual';
      if (existing.wakeSource == 'manual') {
        _wakeAt = existing.wokeAt;
        _wakeEdited = true;
      }
      _separate = existing.separate;
    }
  }

  DateTime get _bedAt {
    final wake = _wakeAt;
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
          title: const Text('Примерное время засыпания'),
          subtitle: Text(
            '${clockLabel(_bed)} · ${_bedEdited
                ? "указано вручную"
                : widget.session?.bedtimeCandidate == null
                ? "обычное время"
                : "настройка будильника + ${widget.journal.fallingAsleepMinutes} мин"}',
          ),
          trailing: const Icon(Icons.edit_outlined),
          onTap: _saving
              ? null
              : () async {
                  final value = await editClock(
                    context,
                    _bed,
                    title: 'Когда примерно заснул(а)',
                  );
                  if (value != null && mounted) {
                    setState(() {
                      _bed = value;
                      _bedEdited = true;
                    });
                  }
                },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Время подъёма'),
          subtitle: Text(clockLabel(TimeOfDay.fromDateTime(_wakeAt))),
          trailing: const Icon(Icons.edit_outlined),
          onTap: _saving
              ? null
              : () async {
                  final value = await editClock(
                    context,
                    TimeOfDay.fromDateTime(_wakeAt),
                    title: 'Когда проснулся / проснулась',
                  );
                  if (value != null && mounted) {
                    setState(() {
                      _wakeAt = DateTime(
                        _wakeAt.year,
                        _wakeAt.month,
                        _wakeAt.day,
                        value.hour,
                        value.minute,
                      );
                      _wakeEdited = true;
                    });
                  }
                },
        ),
        if ((widget.session?.occurrences.length ?? 0) > 1)
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Последний звонок — отдельный сон'),
            value: _separate,
            onChanged: _saving
                ? null
                : (value) => setState(() => _separate = value),
          ),
        Text(
          'Расчётный сон: ${remainingLabel(_wakeAt, _bedAt)}',
          style: const TextStyle(color: morning),
        ),
        const SizedBox(height: 16),
        const Text(
          'Время можно уточнить. Отключение будильника не подтверждает пробуждение.',
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
                        occurrenceId: _separate
                            ? widget.event.occurrenceId
                            : widget.session?.id ?? widget.event.occurrenceId,
                        occurrences: _separate
                            ? [widget.event.occurrenceId]
                            : widget.session?.occurrences ??
                                  [widget.event.occurrenceId],
                        separate: _separate,
                        bedSource: _bedEdited
                            ? 'manual'
                            : widget.session?.bedtimeCandidate == null
                            ? 'habit'
                            : 'alarm_setup',
                        wakeSource: _wakeEdited ? 'manual' : 'alarm',
                        wokeAt: _wakeAt,
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
