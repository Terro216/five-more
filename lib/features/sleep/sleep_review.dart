import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../app/alarm_controller.dart';
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
    this.controller,
  });
  final SleepJournal journal;
  final AlarmEvent event;
  final SleepSession? session;
  final AlarmController? controller;
  @override
  State<SleepReview> createState() => _SleepReviewState();
}

class _SleepReviewState extends State<SleepReview> {
  int _sleep = 3, _wake = 3;
  bool _saving = false, _separate = false;
  bool _bedEdited = false, _wakeEdited = false;
  late SleepSession? _session = widget.session;
  AlarmEvent get _event => _session?.lastEvent ?? widget.event;
  late DateTime _wakeAt = _event.at;
  bool _confirmed = false;
  DateTime? _originalBedAt;
  String? _originalBedSource;
  bool _bedTouched = false;
  late TimeOfDay _bed = _session?.bedtimeCandidate == null
      ? TimeOfDay(
          hour: widget.journal.bedHour,
          minute: widget.journal.bedMinute,
        )
      : TimeOfDay.fromDateTime(
          _session!.bedtimeCandidate!.add(
            Duration(minutes: widget.journal.fallingAsleepMinutes),
          ),
        );
  String? _error;
  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_newEvents);
    final existing = widget.journal.entries
        .where((e) => e.occurrenceId == (_session?.id ?? _event.occurrenceId))
        .firstOrNull;
    if (existing != null) {
      _confirmed = true;
      _originalBedAt = existing.bedAt;
      _originalBedSource = existing.bedSource;
      _sleep = existing.sleepQuality;
      _wake = existing.wakeQuality;
      _bed = TimeOfDay.fromDateTime(existing.bedAt);
      _bedEdited = existing.bedSource == 'manual';
      _wakeAt = existing.wokeAt;
      _wakeEdited = existing.wakeSource == 'manual';
      _separate = existing.separate;
    }
  }

  void _newEvents() {
    if (!mounted || _saving || _confirmed) return;
    final candidates = SleepSession.fromEvents(
      widget.controller!.sleepEvents,
      separateOccurrences: widget.journal.entries
          .where((e) => e.separate)
          .map((e) => e.occurrenceId)
          .toSet(),
    );
    final updated = candidates
        .where((s) => s.occurrences.contains(widget.event.occurrenceId))
        .firstOrNull;
    if (updated == null || updated.lastEvent.eventId == _event.eventId) return;
    setState(() {
      _session = updated;
      if (!_wakeEdited) _wakeAt = updated.lastEvent.at;
      if (!_bedEdited && updated.bedtimeCandidate != null) {
        _bed = TimeOfDay.fromDateTime(
          updated.bedtimeCandidate!.add(
            Duration(minutes: widget.journal.fallingAsleepMinutes),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_newEvents);
    super.dispose();
  }

  DateTime get _bedAt {
    if (!_bedTouched && _originalBedAt != null) return _originalBedAt!;
    if (!_bedEdited && !_confirmed && _session?.bedtimeCandidate != null) {
      return _session!.bedtimeCandidate!.add(
        Duration(minutes: widget.journal.fallingAsleepMinutes),
      );
    }
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
        runSpacing: 8,
        children: List.generate(
          5,
          (i) => ChoiceChip(
            label: Text('${i + 1}'),
            selected: value == i + 1,
            onSelected: _saving ? null : (_) => change(i + 1),
          ),
        ),
      ),
      Text(
        '1 — тяжело · 5 — отлично',
        style: TextStyle(color: context.palette.muted, fontSize: 12),
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
                : (_originalBedSource ?? (_session?.bedtimeCandidate == null ? "habit" : "alarm_setup")) == "habit"
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
                      _bedTouched = true;
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
        if ((_session?.occurrences.length ?? 0) > 1)
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
          style: TextStyle(color: context.palette.morning),
        ),
        const SizedBox(height: 16),
        Text(
          'Время можно уточнить. Отключение будильника не подтверждает пробуждение.',
          style: TextStyle(color: context.palette.muted, height: 1.5),
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
                  if (!_bedAt.isBefore(_wakeAt)) {
                    setState(
                      () => _error = 'Время засыпания должно быть раньше подъёма. Уточни время.',
                    );
                    return;
                  }
                  setState(() => _saving = true);
                  try {
                    await widget.journal.saveEstimate(
                      _separate
                          ? _event.occurrenceId
                          : _session?.id ?? _event.occurrenceId,
                      {
                        'bedtimeCandidate':
                            _session?.bedtimeCandidate?.millisecondsSinceEpoch,
                        'fallingAsleepMinutes':
                            widget.journal.fallingAsleepMinutes,
                        'source': _session?.bedtimeCandidate == null
                            ? 'habit'
                            : 'alarm_setup',
                        'wakeAt': _event.at.millisecondsSinceEpoch,
                      },
                    );
                    await widget.journal.saveEntry(
                      SleepEntry(
                        occurrenceId: _separate
                            ? _event.occurrenceId
                            : _session?.id ?? _event.occurrenceId,
                        occurrences: _separate
                            ? [_event.occurrenceId]
                            : _session?.occurrences ?? [_event.occurrenceId],
                        separate: _separate,
                        bedSource: !_bedTouched && _originalBedSource != null
                            ? _originalBedSource!
                            : _bedEdited
                            ? 'manual'
                            : _session?.bedtimeCandidate == null
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
