import 'alarm.dart';

class SleepEntry {
  const SleepEntry({
    required this.occurrenceId,
    required this.wokeAt,
    required this.bedAt,
    required this.sleepQuality,
    required this.wakeQuality,
  });
  final String occurrenceId;
  final DateTime wokeAt;
  final DateTime bedAt;
  final int sleepQuality;
  final int wakeQuality;
  double get hours => wokeAt.difference(bedAt).inMinutes / 60;
  Map<String, Object?> toJson() => {
    'occurrenceId': occurrenceId,
    'wokeAt': wokeAt.millisecondsSinceEpoch,
    'bedAt': bedAt.millisecondsSinceEpoch,
    'sleepQuality': sleepQuality,
    'wakeQuality': wakeQuality,
  };
  factory SleepEntry.fromJson(Map<String, dynamic> json) => SleepEntry(
    occurrenceId: json['occurrenceId'] as String,
    wokeAt: parseTimestamp(json['wokeAt'])!,
    bedAt: parseTimestamp(json['bedAt'])!,
    sleepQuality: intValue(json['sleepQuality'], 3).clamp(1, 5),
    wakeQuality: intValue(json['wakeQuality'], 3).clamp(1, 5),
  );
}

class VoiceNote {
  const VoiceNote({
    required this.file,
    required this.at,
    required this.seconds,
  });
  final String file;
  final DateTime at;
  final int seconds;
  Map<String, Object?> toJson() => {
    'file': file,
    'at': at.millisecondsSinceEpoch,
    'seconds': seconds,
  };
  factory VoiceNote.fromJson(Map<String, dynamic> json) => VoiceNote(
    file: json['file'] as String,
    at: parseTimestamp(json['at'])!,
    seconds: intValue(json['seconds'], 0),
  );
}

/// Self-reported time in bed is not measured sleep or a medical prescription.
class SleepInsight {
  const SleepInsight(this.hours, this.samples, this.rating);
  final double hours;
  final int samples;
  final double rating;
  static SleepInsight? fromEntries(List<SleepEntry> entries) {
    final bins = <int, List<SleepEntry>>{};
    for (final entry in entries) {
      if (entry.hours < 3 || entry.hours > 14) continue;
      final bucket = (entry.hours * 2).round();
      bins.putIfAbsent(bucket, () => []).add(entry);
    }
    final eligible = bins.entries.where((e) => e.value.length >= 3).toList();
    if (entries.length < 7 || eligible.length < 2) return null;
    double score(List<SleepEntry> values) =>
        values.fold<double>(
          0,
          (sum, e) => sum + (e.sleepQuality + e.wakeQuality) / 2,
        ) /
        values.length;
    eligible.sort((a, b) {
      final order = score(b.value).compareTo(score(a.value));
      return order == 0 ? b.value.length.compareTo(a.value.length) : order;
    });
    final best = eligible.first;
    return SleepInsight(best.key / 2, best.value.length, score(best.value));
  }
}
