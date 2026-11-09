/// Local, optional preferences. Absence means no goal, never a prescribed norm.
class SleepGoals {
  const SleepGoals({
    this.durationMinutes,
    this.bedMinute,
    this.wakeMinute,
    this.toleranceMinutes,
  });
  final int? durationMinutes, bedMinute, wakeMinute, toleranceMinutes;
  bool get hasSchedule =>
      bedMinute != null && wakeMinute != null && toleranceMinutes != null;
  bool get isEmpty => durationMinutes == null && !hasSchedule;
  Map<String, Object?> toJson() => {
    'durationMinutes': durationMinutes,
    'bedMinute': bedMinute,
    'wakeMinute': wakeMinute,
    'toleranceMinutes': toleranceMinutes,
  };
  factory SleepGoals.fromJson(Map<String, dynamic> value) {
    int? valid(String key, int min, int max) {
      final n = value[key];
      return n is int && n >= min && n <= max ? n : null;
    }

    return SleepGoals(
      durationMinutes: valid('durationMinutes', 1, 1440),
      bedMinute: valid('bedMinute', 0, 1439),
      wakeMinute: valid('wakeMinute', 0, 1439),
      toleranceMinutes: valid('toleranceMinutes', 0, 720),
    );
  }

  /// Wall-clock regularity wraps at midnight; actual duration uses instants.
  static int clockDistance(int a, int b) {
    final difference = (a - b).abs() % 1440;
    return difference <= 720 ? difference : 1440 - difference;
  }

  /// A UTC container for a saved wall clock, not an instant to use for duration.
  static DateTime wallTime(DateTime instant, int offsetMinutes) =>
      instant.toUtc().add(Duration(minutes: offsetMinutes));

  static String clock(int minutes) =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';
}
