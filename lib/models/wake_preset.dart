import '../features/challenges/challenge_models.dart';
import '../l10n/strings.dart';
import 'alarm.dart';

/// Shortcuts expand into ordinary alarm settings; no extra persisted state or
/// platform-specific preset identifier can drift from the actual configuration.
enum WakePreset {
  gentle,
  gradual,
  direct;

  String get label => switch (this) {
    gentle => appStrings.gentle,
    gradual => appStrings.buildUp,
    direct => appStrings.noSnoozes,
  };

  String get description => switch (this) {
    gentle => appStrings.relaxedMath5MinOfSnoozeTime,
    gradual => appStrings.math15MinOfSnoozeTimeIncreasing,
    direct => appStrings.mixedChallengesMediumDifficulty,
  };

  Alarm applyTo(Alarm alarm) => switch (this) {
    gentle => alarm.copyWith(
      mixOrder: const [],
      challengeKind: ChallengeKind.math,
      difficulty: ChallengeDifficulty.easy,
      snoozeMinutes: 5,
      maxSnoozes: 1,
      snoozeBudgetMinutes: 5,
      escalateOnSnooze: false,
    ),
    gradual => alarm.copyWith(
      mixOrder: const [],
      challengeKind: ChallengeKind.math,
      difficulty: ChallengeDifficulty.easy,
      snoozeMinutes: 5,
      maxSnoozes: 3,
      snoozeBudgetMinutes: 15,
      escalateOnSnooze: true,
    ),
    direct => alarm.copyWith(
      mixOrder: const [],
      challengeKind: ChallengeKind.mixed,
      difficulty: ChallengeDifficulty.medium,
      snoozeMinutes: 5,
      maxSnoozes: 0,
      snoozeBudgetMinutes: 0,
      escalateOnSnooze: false,
    ),
  };

  bool matches(Alarm alarm) {
    final preset = applyTo(alarm);
    return alarm.mixOrder.isEmpty &&
        alarm.challengeKind == preset.challengeKind &&
        alarm.difficulty == preset.difficulty &&
        alarm.snoozeMinutes == preset.snoozeMinutes &&
        alarm.snoozeBudget == preset.snoozeBudget &&
        alarm.escalateOnSnooze == preset.escalateOnSnooze;
  }

  static WakePreset? matching(Alarm alarm) =>
      values.where((preset) => preset.matches(alarm)).firstOrNull;
}
