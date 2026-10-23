/// Four calm, fixed positions in the snooze area. Every subsequent snooze
/// switches sides; the small vertical offset provides a second visual cue.
enum SnoozePosition {
  topLeft,
  bottomRight,
  bottomLeft,
  topRight;

  bool get onRight => this == bottomRight || this == topRight;
  bool get onBottom => this == bottomRight || this == bottomLeft;
}

/// Pure, reproducible across process restarts and platform implementations.
/// Do not use Object.hash/String.hashCode: their seed can change between runs.
SnoozePosition snoozePositionFor(String occurrenceId, int snoozesUsed) {
  var seed = 0;
  for (final unit in occurrenceId.codeUnits) {
    seed = (seed * 31 + unit) & 0x7fffffff;
  }
  final count = snoozesUsed < 0 ? 0 : snoozesUsed;
  return SnoozePosition.values[(seed + count) % SnoozePosition.values.length];
}
