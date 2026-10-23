import '../features/challenges/challenge_models.dart';
import 'alarm.dart';

/// Shortcuts expand into ordinary alarm settings; no extra persisted state or
/// platform-specific preset identifier can drift from the actual configuration.
enum WakePreset {
  gentle,
  gradual,
  direct;

  String get label => switch (this) {
    gentle => 'Мягко',
    gradual => 'С разгоном',
    direct => 'Без переносов',
  };

  String get description => switch (this) {
    gentle => 'Лёгкий счёт · один перенос на 5 минут',
    gradual => 'Счёт · до 3 переносов по 5 минут · сложность растёт',
    direct => 'Микс заданий · средняя сложность',
  };

  Alarm applyTo(Alarm alarm) => switch (this) {
    gentle => alarm.copyWith(
      challengeKind: ChallengeKind.math,
      difficulty: ChallengeDifficulty.easy,
      snoozeMinutes: 5,
      maxSnoozes: 1,
      escalateOnSnooze: false,
    ),
    gradual => alarm.copyWith(
      challengeKind: ChallengeKind.math,
      difficulty: ChallengeDifficulty.easy,
      snoozeMinutes: 5,
      maxSnoozes: 3,
      escalateOnSnooze: true,
    ),
    direct => alarm.copyWith(
      challengeKind: ChallengeKind.mixed,
      difficulty: ChallengeDifficulty.medium,
      snoozeMinutes: 5,
      maxSnoozes: 0,
      escalateOnSnooze: false,
    ),
  };

  bool matches(Alarm alarm) {
    final preset = applyTo(alarm);
    return alarm.challengeKind == preset.challengeKind &&
        alarm.difficulty == preset.difficulty &&
        alarm.snoozeMinutes == preset.snoozeMinutes &&
        alarm.maxSnoozes == preset.maxSnoozes &&
        alarm.escalateOnSnooze == preset.escalateOnSnooze;
  }

  static WakePreset? matching(Alarm alarm) =>
      values.where((preset) => preset.matches(alarm)).firstOrNull;
}
