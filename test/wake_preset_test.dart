import 'package:five_more/features/challenges/challenge_models.dart';
import 'package:five_more/models/alarm.dart';
import 'package:five_more/models/wake_preset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('presets expose the promised snooze budget and challenge level', () {
    const source = Alarm(id: 'draft', hour: 8, minute: 15);
    final gentle = WakePreset.gentle.applyTo(source);
    expect(gentle.challengeKind, ChallengeKind.math);
    expect(gentle.difficultyForSnoozes(1), ChallengeDifficulty.easy);
    expect(gentle.maxSnoozes * gentle.snoozeMinutes, 5);
    final gradual = WakePreset.gradual.applyTo(source);
    expect(gradual.challengeKind, ChallengeKind.math);
    expect(gradual.difficultyForSnoozes(0), ChallengeDifficulty.easy);
    expect(gradual.difficultyForSnoozes(1), ChallengeDifficulty.medium);
    expect(gradual.difficultyForSnoozes(2), ChallengeDifficulty.hard);
    expect(gradual.maxSnoozes * gradual.snoozeMinutes, 15);
    final direct = WakePreset.direct.applyTo(source);
    expect(direct.challengeKind, ChallengeKind.mixed);
    expect(direct.difficulty, ChallengeDifficulty.medium);
    expect(direct.maxSnoozes, 0);
  });

  test('applying a preset preserves schedule, identity, disabled state and native due time', () {
    final source = Alarm(
      id: 'existing',
      hour: 23,
      minute: 55,
      title: 'Свой будильник',
      weekdays: const [2, 4, 6],
      enabled: false,
      nextAt: DateTime(2026, 10, 24, 23, 55),
    );
    final original = source.toJson();
    for (final preset in WakePreset.values) {
      final changed = preset.applyTo(source);
      for (final field in [
        'id',
        'hour',
        'minute',
        'title',
        'weekdays',
        'enabled',
        'nextAt',
      ]) {
        expect(
          changed.toJson()[field],
          original[field],
          reason: '$preset/$field',
        );
      }
      expect(source.toJson(), original);
    }
  });

  test('preset recognition follows persisted settings without storing a second identity', () {
    for (final preset in WakePreset.values) {
      final applied = preset.applyTo(Alarm.fresh());
      final restored = Alarm.fromJson(applied.toJson());
      expect(WakePreset.matching(restored), preset);
      expect(restored.toJson().containsKey('preset'), isFalse);
      expect(
        WakePreset.matching(restored.copyWith(hour: 16, title: 'Новое время')),
        preset,
      );
    }
  });

  test(
    'custom and legacy alarms are recognized without changing their settings',
    () {
      final custom = Alarm.fresh().copyWith(
        challengeKind: ChallengeKind.sequence,
        difficulty: ChallengeDifficulty.hard,
        maxSnoozes: 2,
        snoozeMinutes: 10,
      );
      final before = custom.toJson();
      expect(WakePreset.matching(custom), isNull);
      expect(custom.toJson(), before);
      final legacyJson = const Alarm(id: 'legacy', hour: 6, minute: 20).toJson()
        ..remove('escalateOnSnooze');
      final legacy = Alarm.fromJson(legacyJson);
      expect(WakePreset.matching(legacy), isNull);
      expect(legacy.escalateOnSnooze, isFalse);
      expect(legacy.difficulty, ChallengeDifficulty.medium);
      expect(legacy.maxSnoozes, 3);
    },
  );

  test('the existing new-alarm default matches the gradual preset', () {
    expect(WakePreset.matching(Alarm.fresh()), WakePreset.gradual);
  });
}
