package dev.ilyamedve.fivemore

/** Emergency/timeout silence must not depend on history or schedule writes succeeding. */
object AlarmSafety {
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
