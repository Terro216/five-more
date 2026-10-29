import 'alarm.dart';

/// An estimate joining nearby wake attempts. Occurrence IDs remain untouched.
class SleepSession {
  const SleepSession({
    required this.id,
    required this.occurrences,
    required this.lastEvent,
    this.bedtimeCandidate,
  });
  final String id;
  final List<String> occurrences;
  final AlarmEvent lastEvent;
  final DateTime? bedtimeCandidate;

  static List<SleepSession> fromEvents(
    List<AlarmEvent> source, {
    Set<String> separateOccurrences = const {},
  }) {
    final events =
        source.where((e) => !e.alarmId.startsWith('preview:')).toList()
          ..sort((a, b) => a.at.compareTo(b.at));
    final result = <SleepSession>[];
    final ends = events.where(
      (e) => ['dismissed', 'emergency', 'emergency_dismissed'].contains(e.type),
    );
    for (final end in ends) {
      final start =
          events
              .where(
                (e) =>
                    e.occurrenceId == end.occurrenceId &&
                    ['fired', 'ringing'].contains(e.type),
              )
              .firstOrNull
              ?.at ??
          end.at;
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
      if (previous != null &&
          !separateOccurrences.contains(end.occurrenceId) &&
          (previous.occurrences.contains(end.occurrenceId) ||
              (!start.isBefore(previous.lastEvent.at) &&
                  rearmed &&
                  start.difference(previous.lastEvent.at) <=
                      const Duration(minutes: 90)))) {
        result[result.length - 1] = SleepSession(
          id: previous.id,
          occurrences: {...previous.occurrences, end.occurrenceId}.toList(),
          lastEvent: end,
          bedtimeCandidate: previous.bedtimeCandidate,
        );
      } else {
        final armed = events
            .where(
              (e) =>
                  e.type == 'armed' &&
                  !e.at.isAfter(start) &&
                  start.difference(e.at) >= const Duration(hours: 2) &&
                  start.difference(e.at) <= const Duration(hours: 16) &&
                  (e.at.hour >= 18 || e.at.hour < 6),
            )
            .lastOrNull;
        result.add(
          SleepSession(
            id: end.occurrenceId,
            occurrences: [end.occurrenceId],
            lastEvent: end,
            bedtimeCandidate: armed?.at,
          ),
        );
      }
    }
    return result;
  }
}
