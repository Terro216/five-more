/// Stable per native occurrence, including after process death. Each next
/// snooze jumps to one of the five other tiles, without a repeating route.
int snoozeTileFor(String occurrenceId, int snoozesUsed) {
  var seed = 1;
  for (final unit in occurrenceId.codeUnits) {
    seed = (seed * 31 + unit) % 2147483647;
  }
  var slot = seed % 6;
  for (var count = 0; count < snoozesUsed.clamp(0, 300); count++) {
    seed = (seed * 48271) % 2147483647;
    slot = (slot + 1 + seed % 5) % 6;
  }
  return slot;
}
