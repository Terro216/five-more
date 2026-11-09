import 'alarm.dart';

/// A proposal, never evidence of actual sleep or waking. A wake chain spans at
/// most three hours with at most 90 minutes between attempts. Distinct alarms
/// prepared before the chain can join it; a newly set daytime nap cannot.
class SleepSession {
  const SleepSession({
    required this.id,
    required this.occurrences,
    required this.lastEvent,
    this.bedtimeCandidate,
    this.firstStartedAt,
  });
  final String id;
  final List<String> occurrences;
  final AlarmEvent lastEvent;
  final DateTime? bedtimeCandidate;
  final DateTime? firstStartedAt;

  static List<SleepSession> fromEvents(
    List<AlarmEvent> source, {
    Set<String> separateOccurrences = const {},
  }) {
    final events =
        source.where((e) => !e.alarmId.startsWith('preview:')).toList()
          ..sort((a, b) => a.at.compareTo(b.at));
    final latestEnds = <String, AlarmEvent>{};
    for (final event in events) {
      if (const [
        'dismissed',
        'emergency',
        'emergency_dismissed',
      ].contains(event.type)) {
        latestEnds[event.occurrenceId] = event;
      }
    }
    final ends = latestEnds.values.toList()
      ..sort((a, b) => a.at.compareTo(b.at));
    final result = <SleepSession>[];
    for (final end in ends) {
      final start =
          events
              .where(
                (e) =>
                    e.occurrenceId == end.occurrenceId &&
                    const ['fired', 'ringing'].contains(e.type),
              )
              .firstOrNull
              ?.at ??
          end.at;
      // Only a recent manual setup of this alarm can be its bedtime estimate.
      // No clock-hour or minimum-duration rule pretends to define human sleep.
      final armed = events
          .where(
            (e) =>
                e.type == 'armed' &&
                e.alarmId == end.alarmId &&
                !e.at.isAfter(start) &&
                start.difference(e.at) <= const Duration(hours: 36) &&
                (e.nextAt == null ||
                    e.nextAt!.difference(start).abs() <=
                        const Duration(minutes: 15)),
          )
          .lastOrNull;
      final previous = result.lastOrNull;
      final rearmed =
          previous != null &&
          events.any(
            (e) =>
                e.type == 'armed' &&
                e.alarmId == end.alarmId &&
                !e.at.isBefore(previous.lastEvent.at) &&
                e.at.difference(previous.lastEvent.at) <=
                    const Duration(minutes: 15) &&
                e.nextAt != null &&
                e.nextAt!.isAfter(previous.lastEvent.at) &&
                !e.nextAt!.isAfter(
                  previous.lastEvent.at.add(const Duration(minutes: 90)),
                ),
          );
      final preparedOtherAlarm =
          previous != null &&
          end.alarmId != previous.lastEvent.alarmId &&
          (armed == null ||
              armed.at.isBefore(
                previous.firstStartedAt ?? previous.lastEvent.at,
              ));
      final close =
          previous != null &&
          !start.isBefore(previous.firstStartedAt ?? previous.lastEvent.at) &&
          start.difference(previous.lastEvent.at) <=
              const Duration(minutes: 90) &&
          end.at.difference(previous.firstStartedAt ?? previous.lastEvent.at) <=
              const Duration(hours: 3);
      if (previous != null &&
          !separateOccurrences.contains(end.occurrenceId) &&
          close &&
          (rearmed || preparedOtherAlarm)) {
        result[result.length - 1] = SleepSession(
          id: previous.id,
          occurrences: {...previous.occurrences, end.occurrenceId}.toList(),
          lastEvent: end,
          bedtimeCandidate:
              previous.bedtimeCandidate ??
              (armed != null &&
                      armed.at.isBefore(
                        previous.firstStartedAt ?? previous.lastEvent.at,
                      )
                  ? armed.at
                  : null),
          firstStartedAt: previous.firstStartedAt,
        );
      } else {
        result.add(
          SleepSession(
            id: end.occurrenceId,
            occurrences: [end.occurrenceId],
            lastEvent: end,
            bedtimeCandidate: armed?.at,
            firstStartedAt: start,
          ),
        );
      }
    }
    return result;
  }
}
