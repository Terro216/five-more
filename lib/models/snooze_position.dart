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

class SnoozeAppearance {
  const SnoozeAppearance(
    this.x,
    this.y,
    this.widthFactor,
    this.height,
    this.colorIndex,
    this.radius,
  );
  final double x, y, widthFactor, height, radius;
  final int colorIndex;
}

SnoozeAppearance snoozeAppearanceFor(String occurrenceId, int snoozesUsed) {
  var seed = 2166136261;
  for (final unit in occurrenceId.codeUnits) {
    seed = ((seed ^ unit) * 16777619) & 0x7fffffff;
  }
  final count = snoozesUsed < 0 ? 0 : snoozesUsed;
  // Switch sides every time, with independent vertical jumps and styling.
  // Neither the old centre nor a process restart provides a repeat-tap shortcut.
  final position = (
    ((seed + count).isEven ? -1.0 : 1.0),
    [-1.0, 1.0, -.2, .6][(seed + count * 3) % 4],
  );
  return SnoozeAppearance(
    position.$1,
    position.$2,
    [.64, .46, .38, .52, .34][(seed + count) % 5],
    [72.0, 56.0, 88.0, 64.0][(seed + count) % 4],
    (seed + count) % 5,
    [6.0, 28.0, 44.0, 12.0][(seed + count) % 4],
  );
}
