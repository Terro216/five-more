import 'alarm.dart';

/// A user's report about one real test ring, never proof inferred from an event.
class DeviceAlarmCheck {
  const DeviceAlarmCheck({
    required this.sourceAlarmId,
    required this.previewAlarmId,
    required this.startedAt,
    required this.dueAt,
    this.heard,
    this.confirmedAt,
  });

  final String sourceAlarmId;
  final String previewAlarmId;
  final DateTime startedAt;
  final DateTime dueAt;
  final bool? heard;
  final DateTime? confirmedAt;

  bool get pending => heard == null;
  bool canConfirm(DateTime now) => pending && !now.isBefore(dueAt);

  DeviceAlarmCheck confirmed({required bool heard, required DateTime at}) =>
      DeviceAlarmCheck(
        sourceAlarmId: sourceAlarmId,
        previewAlarmId: previewAlarmId,
        startedAt: startedAt,
        dueAt: dueAt,
        heard: heard,
        confirmedAt: at,
      );

  Map<String, Object?> toJson() => {
    'sourceAlarmId': sourceAlarmId,
    'previewAlarmId': previewAlarmId,
    'startedAt': startedAt.millisecondsSinceEpoch,
    'dueAt': dueAt.millisecondsSinceEpoch,
    'heard': heard,
    'confirmedAt': confirmedAt?.millisecondsSinceEpoch,
  };

  /// A malformed optional check must not hide the user's existing alarms.
  static DeviceAlarmCheck? tryFromJson(Object? value) {
    try {
      return _fromJson(value);
    } on ArgumentError {
      return null;
    } on FormatException {
      return null;
    }
  }

  static DeviceAlarmCheck? _fromJson(Object? value) {
    if (value is! Map) return null;
    final source = value['sourceAlarmId'];
    final preview = value['previewAlarmId'];
    final start = parseTimestamp(value['startedAt']);
    final due = parseTimestamp(value['dueAt']);
    final heard = value['heard'];
    final confirmed = parseTimestamp(value['confirmedAt']);
    if (source is! String ||
        source.isEmpty ||
        source.startsWith('preview:') ||
        preview is! String ||
        !preview.startsWith('preview:') ||
        preview.length <= 8 ||
        start == null ||
        due == null ||
        due.isBefore(start) ||
        (heard != null && heard is! bool) ||
        (heard != null && (confirmed == null || confirmed.isBefore(due)))) {
      return null;
    }
    return DeviceAlarmCheck(
      sourceAlarmId: source,
      previewAlarmId: preview,
      startedAt: start,
      dueAt: due,
      heard: heard as bool?,
      confirmedAt: heard == null ? null : confirmed,
    );
  }
}
