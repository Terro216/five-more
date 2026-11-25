import 'package:flutter/material.dart';

import '../../app/alarm_controller.dart';
import '../../models/alarm.dart';
import '../../models/sleep_entry.dart';
import '../../models/sleep_session.dart';
import '../../services/sleep_journal.dart';
import '../../widgets/time_composer.dart';
import 'sleep_review.dart';

/// Reviews are chosen by date. Saving one never opens the next automatically.
class SleepReviews extends StatelessWidget {
  const SleepReviews({
    super.key,
    required this.journal,
    required this.controller,
  });
  final SleepJournal journal;
  final AlarmController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Дневник сна')),
    body: AnimatedBuilder(
      animation: Listenable.merge([journal, controller]),
      builder: (context, _) {
        final sessions = SleepSession.fromEvents(
          controller.sleepEvents,
          separateOccurrences: journal.entries
              .where((e) => e.separate)
              .map((e) => e.occurrenceId)
              .toSet(),
        );
        final rows = <({SleepSession session, SleepEntry? entry})>[];
        final saved = <String>{};
        for (final session in sessions) {
          final entry = journal.entries
              .where(
                (e) =>
                    e.occurrenceId == session.id ||
                    session.occurrences.any(e.occurrences.contains),
              )
              .firstOrNull;
          if (entry != null && !saved.add(entry.occurrenceId)) continue;
          rows.add((
            session: entry == null
                ? session
                : SleepSession(
                    id: entry.occurrenceId,
                    occurrences: entry.occurrences,
                    lastEvent: session.lastEvent,
                  ),
            entry: entry,
          ));
        }
        for (final entry in journal.entries.where(
          (e) => !saved.contains(e.occurrenceId),
        )) {
          rows.add((
            session: SleepSession(
              id: entry.occurrenceId,
              occurrences: entry.occurrences,
              lastEvent: AlarmEvent(
                eventId: 'review:${entry.occurrenceId}',
                alarmId: 'history',
                occurrenceId: entry.occurrenceId,
                type: 'dismissed',
                at: entry.wokeAt,
              ),
            ),
            entry: entry,
          ));
        }
        rows.sort(
          (a, b) => b.session.lastEvent.at.compareTo(a.session.lastEvent.at),
        );
        final pending = sessions
            .where((s) => !s.occurrences.any(journal.reported))
            .toList();
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Выбери дату, чтобы оценить сон или уточнить сохранённую запись.',
            ),
            if (pending.isNotEmpty)
              TextButton(
                onPressed: () async {
                  try {
                    await journal.skipAll(pending.expand((s) => s.occurrences));
                  } catch (_) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Не удалось сохранить. Попробуй ещё раз.',
                          ),
                        ),
                      );
                    }
                  }
                },
                child: Text('Пропустить все без оценки (${pending.length})'),
              ),
            if (rows.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('Здесь появятся сны после завершённых подъёмов.'),
              ),
            for (final row in rows)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '${sleepDateLabel(row.entry?.wokeAt ?? row.session.lastEvent.at)} · '
                  '${clockLabel(TimeOfDay.fromDateTime(row.entry?.wokeAt ?? row.session.lastEvent.at))}',
                ),
                subtitle: Text(
                  row.entry != null
                      ? 'Сон ${row.entry!.sleepQuality}/5 · подъём ${row.entry!.wakeQuality}/5'
                            '${journal.comments[row.entry!.occurrenceId] == null ? '' : '\n${journal.comments[row.entry!.occurrenceId]}'}'
                      : row.session.occurrences.any(journal.reported)
                      ? 'Оценка пропущена'
                      : 'Без оценки',
                ),
                trailing: Icon(
                  row.entry == null
                      ? Icons.rate_review_outlined
                      : Icons.edit_outlined,
                ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => SleepReview(
                      journal: journal,
                      controller: controller,
                      event: row.session.lastEvent,
                      session: row.session,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );
}
