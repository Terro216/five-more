package dev.ilyamedve.fivemore

/** Countdown identity is independent of the real alarm PendingIntent. */
object UpcomingAlarmRules {
    data class Candidate(val id: String, val occurrence: String, val state: String,
        val enabled: Boolean, val nextAt: Long, val title: String = "") {
        val key: String get() = "$id|$occurrence|$nextAt"
    }

    fun next(alarms: List<Candidate>, now: Long): Candidate? {
        if (alarms.any { it.enabled && it.state == "ringing" && !AlarmRules.isPreviewId(it.id) }) return null
        return alarms.filter { it.enabled && !AlarmRules.isPreviewId(it.id) &&
            it.state in listOf("scheduled", "snoozed") && it.nextAt > now }
            .minWithOrNull(compareBy<Candidate> { it.nextAt }.thenBy { it.id })
    }
}
