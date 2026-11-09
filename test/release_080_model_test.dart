import 'package:five_more/models/alarm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy fields retain challenges, title and vibration without opting into cleanup', () {
    final old = {
      'id': 'old',
      'hour': 7,
      'minute': 30,
      'enabled': true,
      'title': 'Пора вставать',
      'challengeKind': 'qr',
      'qrValue': 'saved',
    };
    final alarm = Alarm.fromJson(old);
    expect(alarm.requiresChallenge, isTrue);
    expect(alarm.title, 'Пора вставать');
    expect(alarm.vibration, isTrue);
    expect(alarm.deleteAfterDismiss, isFalse);
    expect(alarm.escalateOnSnooze, isFalse);
  });
  test('new settings and empty title survive storage, preview copies and arbitrary ramp seconds', () {
    for (var seconds = 0; seconds <= 60; seconds++) {
      final alarm = Alarm.fresh().copyWith(
        weekdays: [],
        vibration: false,
        deleteAfterDismiss: true,
        volumeRampSeconds: seconds,
        configurationId: 'revision',
      );
      final restored = Alarm.fromJson(alarm.toJson()).copyWith();
      expect(restored.requiresChallenge, isFalse);
      expect(restored.displayTitle, '');
      expect(restored.systemTitle, 'Будильник на 07:30');
      expect(restored.vibration, isFalse);
      expect(restored.deleteAfterDismiss, isTrue);
      expect(restored.volumeRampSeconds, seconds);
      expect(restored.configurationId, 'revision');
    }
  });
  test('repeating schedule clears one-shot cleanup permanently', () {
    final oneShot = Alarm.fresh().copyWith(
      weekdays: [],
      deleteAfterDismiss: true,
    );
    final repeating = oneShot.copyWith(weekdays: [1]);
    expect(repeating.deleteAfterDismiss, isFalse);
    expect(repeating.copyWith(weekdays: []).deleteAfterDismiss, isFalse);
    expect(
      Alarm.fromJson({
        ...oneShot.toJson(),
        'weekdays': [1],
      }).deleteAfterDismiss,
      isFalse,
    );
  });
}
