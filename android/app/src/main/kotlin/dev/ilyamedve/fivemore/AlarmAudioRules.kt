package dev.ilyamedve.fivemore

/** Monotonic time belongs to a boot, and a manual allowance belongs to a ring. */
object AlarmAudioRules {
    const val QUIET_MS = 30_000L
    const val RETURN_MS = 2_500L
    fun remaining(now: Long, deadline: Long, savedBoot: Int, currentBoot: Int): Long =
        if (currentBoot < 0 || savedBoot != currentBoot) 0L else (deadline - now).coerceIn(0L, QUIET_MS)

    fun canQuiet(used: Int, remaining: Long): Boolean = used in 0..1 && remaining == 0L

    fun level(elapsed: Long, rampSeconds: Int, quietRemaining: Long, returningElapsed: Long?, callActive: Boolean): Float {
        if (callActive) return 0f
        val ramp = if (rampSeconds <= 0) 1f else (0.08f + 0.92f * elapsed.coerceAtLeast(0L) / (rampSeconds * 1000f)).coerceAtMost(1f)
        val quiet = if (quietRemaining > 0L) 0.4f else 1f
        val returning = returningElapsed?.let { (it.coerceAtLeast(0L) / RETURN_MS.toFloat()).coerceAtMost(1f) } ?: 1f
        return minOf(ramp, quiet) * returning
    }
}
