package dev.ilyamedve.fivemore

/** Emergency/timeout silence must not depend on history or schedule writes succeeding. */
object AlarmSafety {
    /** Recovery may resolve a ring without a dismiss action. Never start media from a boot receiver,
     * and never interpret unreadable state as proof that a currently playing alarm may be stopped. */
    fun stopRecoveredPlaybackIfIdle(hasRingingAlarm: () -> Boolean, stopPlayback: () -> Unit) {
        if (!hasRingingAlarm()) stopPlayback()
    }

    fun <T> resolveOrSilence(
        operation: () -> T,
        silenceWithoutPersistence: () -> Unit,
        failure: (Exception) -> T,
    ): T = try {
        operation()
    } catch (error: Exception) {
        silenceWithoutPersistence()
        failure(error)
    }
}
