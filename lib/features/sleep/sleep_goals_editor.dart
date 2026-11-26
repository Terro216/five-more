import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
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
        : appClockMinute(widget.journal.goals.bedMinute!),
  );
  late final _wake = TextEditingController(
    text: widget.journal.goals.wakeMinute == null
        ? ''
        : appClockMinute(widget.journal.goals.wakeMinute!),
  );
  late final _tolerance = TextEditingController(
    text: widget.journal.goals.toleranceMinutes?.toString() ?? '',
  );
  bool _saving = false;
  String? _error;
  int? _time(String value) {
    final match = RegExp(
      r'^(\d{1,2}):(\d{2})\s*(am|pm)?$',
      caseSensitive: false,
    ).firstMatch(value.trim());
    if (match == null) return null;
    final hour = int.parse(match[1]!), minute = int.parse(match[2]!);
    if (minute >= 60 || hour >= 24) return null;
    final period = match[3]?.toLowerCase();
    if (period == null) return hour * 60 + minute;
    if (hour < 1 || hour > 12) return null;
    return (hour % 12 + (period == 'pm' ? 12 : 0)) * 60 + minute;
  }

  String? _integer(String? raw, int min, int max) {
    final number = int.tryParse(raw ?? '');
    return number != null && number >= min && number <= max
        ? null
        : appStrings.wholeNumberFromTo(min, max);
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
    appBar: AppBar(title: Text(context.strings.myGoal)),
    body: Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(context.strings.personalGoalPrivacy),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(context.strings.sleepDuration),
            value: _duration,
            onChanged: _saving ? null : (v) => setState(() => _duration = v),
          ),
          if (_duration)
            TextFormField(
              controller: _minutes,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: context.strings.targetDuration,
                suffixText: context.strings.min,
              ),
              validator: (v) => _integer(v, 1, 1440),
            ),
          const SizedBox(height: 24),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(context.strings.regularSchedule),
            value: _schedule,
            onChanged: _saving ? null : (v) => setState(() => _schedule = v),
          ),
          if (_schedule) ...[
            TextFormField(
              controller: _bed,
              keyboardType: localeUsesDayPeriod
                  ? TextInputType.text
                  : TextInputType.datetime,
              decoration: InputDecoration(
                labelText: context.strings.goToBedAt,
                hintText: localeUsesDayPeriod
                    ? appClock(19, 30)
                    : context.strings.hhMm,
              ),
              validator: (v) => _time(v ?? '') == null
                  ? context.strings.enterATimeFrom0000To
                  : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _wake,
              keyboardType: localeUsesDayPeriod
                  ? TextInputType.text
                  : TextInputType.datetime,
              decoration: InputDecoration(
                labelText: context.strings.wakeUpAt,
                hintText: localeUsesDayPeriod
                    ? appClock(19, 30)
                    : context.strings.hhMm,
              ),
              validator: (v) => _time(v ?? '') == null
                  ? context.strings.enterATimeFrom0000To
                  : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _tolerance,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: context.strings.allowedVariation,
                suffixText: context.strings.min,
              ),
              validator: (v) => _integer(v, 0, 720),
            ),
            const SizedBox(height: 16),
            Text(context.strings.bedtimeComparisonHint),
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
                          _error = context.strings.couldntSaveTheGoalTryAgain;
                        });
                      }
                    }
                  },
            child: Text(context.strings.saveGoal),
          ),
        ],
      ),
    ),
  );
}
