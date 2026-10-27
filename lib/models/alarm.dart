import 'dart:math';

import '../features/challenges/challenge_models.dart';

String newAlarmId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

DateTime? parseTimestamp(Object? value) {
  if (value is num) return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  if (value is String) return DateTime.tryParse(value)?.toLocal();
  return null;
}

DateTime? parseNextTimestamp(Object? value) =>
    value is num && value <= 0 ? null : parseTimestamp(value);

int intValue(Object? value, int fallback) =>
    value is num ? value.toInt() : fallback;

class Alarm {
  const Alarm({
    required this.id,
    required this.hour,
    required this.minute,
    this.title = '',
    this.weekdays = const [],
    this.enabled = true,
    this.snoozeMinutes = 5,
    this.maxSnoozes = 3,
    this.challengeKind = ChallengeKind.math,
    this.difficulty = ChallengeDifficulty.medium,
    this.escalateOnSnooze = false,
    this.moveSnoozeButton = false,
    this.nextAt,
    this.oneShotAt,
    this.mixOrder = const [],
    this.qrValue = '',
    this.sound = 'system',
    this.soundLabel = 'Системный будильник',
  });

  factory Alarm.fresh() => Alarm(
    id: newAlarmId(),
    hour: 7,
    minute: 30,
    weekdays: const [1, 2, 3, 4, 5],
    difficulty: ChallengeDifficulty.easy,
    escalateOnSnooze: true,
  );

  final String id;
  final int hour;
  final int minute;
  final String title;
  final List<int> weekdays;
  final bool enabled;
  final int snoozeMinutes;
  final int maxSnoozes;
  final ChallengeKind challengeKind;
  final ChallengeDifficulty difficulty;
  final bool escalateOnSnooze;
  final bool moveSnoozeButton;
  final DateTime? nextAt;
  final DateTime? oneShotAt;
  final List<ChallengeKind> mixOrder;
  final String qrValue;
  final String sound;
  final String soundLabel;

  String get timeLabel =>
      '${hour.toString().padLeft(2, '0')}:'
      '${minute.toString().padLeft(2, '0')}';
  String get displayTitle =>
      title.trim().isEmpty ? 'Пора вставать' : title.trim();
  String get repeatLabel => alarmRepeatLabel(this);

  /// Use the native occurrence's counter, so reopening Flutter cannot lower
  /// the level. The saved difficulty always remains the first-ring baseline.
  ChallengeDifficulty difficultyForSnoozes(int snoozesUsed) {
    if (!escalateOnSnooze) return difficulty;
    final level =
        (difficulty.index +
                snoozesUsed.clamp(0, ChallengeDifficulty.values.length - 1))
            .clamp(0, ChallengeDifficulty.values.length - 1);
    return ChallengeDifficulty.values[level];
  }

  static bool _sameDays(List<int> actual, List<int> expected) =>
      actual.length == expected.length && expected.every(actual.contains);

  /// A calendar calculation, deliberately avoiding Duration(days: 1), which
  /// would drift local wall-clock time across daylight-saving transitions.
  DateTime nextOccurrence(DateTime now) {
    if (oneShotAt != null && weekdays.isEmpty) return oneShotAt!;
    final localNow = now.toLocal();
    for (var offset = 0; offset <= 7; offset++) {
      final candidate = DateTime(
        localNow.year,
        localNow.month,
        localNow.day + offset,
        hour,
        minute,
      );
      if (!candidate.isAfter(localNow)) continue;
      if (weekdays.isEmpty || weekdays.contains(candidate.weekday)) {
        return candidate;
      }
    }
    throw StateError('Alarm must have valid weekdays');
  }

  Alarm copyWith({
    int? hour,
    int? minute,
    String? title,
    List<int>? weekdays,
    bool? enabled,
    int? snoozeMinutes,
    int? maxSnoozes,
    ChallengeKind? challengeKind,
    ChallengeDifficulty? difficulty,
    bool? escalateOnSnooze,
    bool? moveSnoozeButton,
    DateTime? nextAt,
    bool clearNextAt = false,
    DateTime? oneShotAt,
    bool clearOneShotAt = false,
    List<ChallengeKind>? mixOrder,
    String? qrValue,
    String? sound,
    String? soundLabel,
  }) => Alarm(
    id: id,
    oneShotAt: clearOneShotAt ? null : oneShotAt ?? this.oneShotAt,
    mixOrder: List.unmodifiable(mixOrder ?? this.mixOrder),
    qrValue: qrValue ?? this.qrValue,
    sound: sound ?? this.sound,
    soundLabel: soundLabel ?? this.soundLabel,
    hour: hour ?? this.hour,
    minute: minute ?? this.minute,
    title: title ?? this.title,
    weekdays: List.unmodifiable(weekdays ?? this.weekdays),
    enabled: enabled ?? this.enabled,
    snoozeMinutes: snoozeMinutes ?? this.snoozeMinutes,
    maxSnoozes: maxSnoozes ?? this.maxSnoozes,
    challengeKind: challengeKind ?? this.challengeKind,
    difficulty: difficulty ?? this.difficulty,
    escalateOnSnooze: escalateOnSnooze ?? this.escalateOnSnooze,
    moveSnoozeButton: moveSnoozeButton ?? this.moveSnoozeButton,
    nextAt: clearNextAt ? null : nextAt ?? this.nextAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'oneShotAt': oneShotAt?.millisecondsSinceEpoch,
    'mixOrder': mixOrder.map((kind) => kind.name).toList(),
    'qrValue': qrValue,
    'sound': sound,
    'soundLabel': soundLabel,
    'hour': hour,
    'minute': minute,
    'title': title,
    'weekdays': weekdays,
    'enabled': enabled,
    'snoozeMinutes': snoozeMinutes,
    'maxSnoozes': maxSnoozes,
    'challengeKind': challengeKind.name,
    'difficulty': difficulty.name,
    'escalateOnSnooze': escalateOnSnooze,
    'moveSnoozeButton': moveSnoozeButton,
    if (nextAt != null) 'nextAt': nextAt!.millisecondsSinceEpoch,
  };

  factory Alarm.fromJson(Map<String, dynamic> json) {
    final weekdays =
        (json['weekdays'] as List? ?? const [])
            .whereType<num>()
            .map((day) => day.toInt())
            .where((day) => day >= 1 && day <= 7)
            .toSet()
            .toList()
          ..sort();
    return Alarm(
      id: json['id'] as String,
      oneShotAt: parseNextTimestamp(json['oneShotAt']),
      mixOrder: (json['mixOrder'] as List? ?? [])
          .whereType<String>()
          .map(
            (name) => ChallengeKind.values
                .where((k) => k.name == name && k != ChallengeKind.mixed)
                .firstOrNull,
          )
          .whereType<ChallengeKind>()
          .take(12)
          .toList(),
      qrValue: json['qrValue'] as String? ?? '',
      sound: json['sound'] as String? ?? 'system',
      soundLabel: json['soundLabel'] as String? ?? 'Системный будильник',
      hour: intValue(json['hour'], 7).clamp(0, 23),
      minute: intValue(json['minute'], 30).clamp(0, 59),
      title: json['title'] as String? ?? '',
      weekdays: weekdays,
      enabled: json['enabled'] == true,
      snoozeMinutes: intValue(json['snoozeMinutes'], 5).clamp(1, 30),
      maxSnoozes: intValue(json['maxSnoozes'], 3).clamp(0, 10),
      challengeKind: ChallengeKind.values.firstWhere(
        (kind) => kind.name == json['challengeKind'],
        orElse: () => ChallengeKind.math,
      ),
      difficulty: ChallengeDifficulty.values.firstWhere(
        (level) => level.name == json['difficulty'],
        orElse: () => ChallengeDifficulty.medium,
      ),
      // Pre-0.3 alarms keep the level their owner chose until explicitly opted in.
      escalateOnSnooze: json['escalateOnSnooze'] == true,
      // Relocation is an explicit choice; older alarms retain a fixed button.
      moveSnoozeButton: json['moveSnoozeButton'] == true,
      nextAt: parseNextTimestamp(json['nextAt']),
    );
  }
}

const shortWeekdays = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];

String alarmRepeatLabel(Alarm alarm) {
  if (alarm.weekdays.isEmpty) return 'Один раз';
  if (alarm.weekdays.length == 7) return 'Каждый день';
  if (Alarm._sameDays(alarm.weekdays, const [1, 2, 3, 4, 5])) return 'Будни';
  if (Alarm._sameDays(alarm.weekdays, const [6, 7])) return 'Выходные';
  final days = [...alarm.weekdays]..sort();
  return days.map((day) => shortWeekdays[day - 1]).join(', ');
}

class AlarmEvent {
  const AlarmEvent({
    required this.eventId,
    required this.alarmId,
    required this.occurrenceId,
    required this.type,
    required this.at,
    this.snoozesUsed = 0,
    this.nextAt,
  });
  final String eventId;
  final String alarmId;
  final String occurrenceId;
  final String type;
  final DateTime at;
  final int snoozesUsed;
  final DateTime? nextAt;

  factory AlarmEvent.fromJson(Map<String, dynamic> json) => AlarmEvent(
    eventId: json['eventId'] as String,
    alarmId: json['id'] as String? ?? '',
    occurrenceId: json['occurrenceId'] as String? ?? '',
    type: json['type'] as String? ?? 'unknown',
    at: parseTimestamp(json['at']) ?? DateTime.fromMillisecondsSinceEpoch(0),
    snoozesUsed: intValue(json['snoozesUsed'], 0),
    nextAt: parseNextTimestamp(json['nextAt']),
  );
  Map<String, Object?> toJson() => {
    'eventId': eventId,
    'id': alarmId,
    'occurrenceId': occurrenceId,
    'type': type,
    'at': at.millisecondsSinceEpoch,
    'snoozesUsed': snoozesUsed,
    if (nextAt != null) 'nextAt': nextAt!.millisecondsSinceEpoch,
  };

  String get label => switch (type) {
    'fired' || 'ringing' => 'Будильник зазвонил',
    'snoozed' => 'Перенос №$snoozesUsed',
    'dismissed' => 'Будильник отключён',
    'emergency_dismissed' || 'emergency' => 'Аварийное отключение',
    'timed_out' => 'Остановлен после 15 минут',
    'cancelled' => 'Будильник отменён',
    'missed' => 'Срабатывание пропущено',
    'schedule_failed' => 'Не удалось назначить следующее срабатывание',
    _ => 'Событие будильника',
  };
}

class RingingAlarm {
  const RingingAlarm({
    required this.alarm,
    required this.occurrenceId,
    required this.firedAt,
    required this.snoozesUsed,
  });
  final Alarm alarm;
  final String occurrenceId;
  final DateTime firedAt;
  final int snoozesUsed;
  int get snoozesRemaining => (alarm.maxSnoozes - snoozesUsed).clamp(0, 10);
  ChallengeDifficulty get challengeDifficulty =>
      alarm.difficultyForSnoozes(snoozesUsed);

  factory RingingAlarm.fromJson(Map<String, dynamic> json) {
    final nested = json['alarm'];
    final config = nested is Map ? Map<String, dynamic>.from(nested) : json;
    return RingingAlarm(
      alarm: Alarm.fromJson(config),
      occurrenceId: json['occurrenceId'] as String? ?? config['id'] as String,
      firedAt: parseTimestamp(json['firedAt']) ?? DateTime.now(),
      snoozesUsed: intValue(json['snoozesUsed'], 0),
    );
  }
}
