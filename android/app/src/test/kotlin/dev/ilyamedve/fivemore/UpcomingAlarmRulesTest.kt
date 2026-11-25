package dev.ilyamedve.fivemore

import org.junit.Assert.*
import org.junit.Test

class UpcomingAlarmRulesTest {
    private fun alarm(id: String, at: Long, state: String = "scheduled", enabled: Boolean = true) =
        UpcomingAlarmRules.Candidate(id, "occurrence", state, enabled, at)

    @Test fun countdownSelectsTheNearestRealFutureAlarm() {
        val selected = UpcomingAlarmRules.next(listOf(
            alarm("later", 300), alarm("first", 200), alarm("preview:test", 150),
            alarm("off", 120, enabled = false), alarm("expired", 99)), 100)
        assertEquals("first", selected?.id)
    }

    @Test fun ringingHidesCountdownAndSnoozeCanBecomeNext() {
        assertNull(UpcomingAlarmRules.next(listOf(alarm("ring", 0, "ringing"), alarm("next", 200)), 100))
        assertEquals("nap", UpcomingAlarmRules.next(listOf(alarm("next", 300), alarm("nap", 200, "snoozed")), 100)?.id)
    }

    @Test fun dismissalIdentitySurvivesRestartButChangesForANewTimeOrOccurrence() {
        val original = alarm("a", 200)
        assertEquals(original.key, alarm("a", 200).key)
        assertNotEquals(original.key, alarm("a", 300).key)
        assertNotEquals(original.key, original.copy(occurrence = "tomorrow").key)
    }
}
