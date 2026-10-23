package dev.ilyamedve.fivemore

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AlarmRecoveryTest {
    private val now = 10_000_000L
    private val maximumRing = 15 * 60_000L

    private fun plan(
        state: String = "scheduled",
        nextAt: Long = now + 60_000L,
        ringingSince: Long = now - 10_000L,
        enabled: Boolean = true,
        clockChanged: Boolean = false,
        preview: Boolean = false,
        skipRinging: Boolean = false,
    ) = AlarmRules.recoveryPlan(enabled, state, nextAt, ringingSince, now, maximumRing, clockChanged, preview, skipRinging)

    @Test fun futureScheduledAndSnoozedRingsKeepTheirOriginalDueTime() {
        for (state in listOf("scheduled", "snoozed")) {
            val recovered = plan(state, nextAt = now + 123_456L)
            assertEquals(AlarmRules.RecoveryAction.REARM, recovered.action)
            assertEquals(now + 123_456L, recovered.nextAt)
            assertNull(recovered.event)
        }
    }

    @Test fun recentlyMissedRingGetsATwoSecondRecoveryWithoutANewOccurrence() {
        for (state in listOf("scheduled", "snoozed")) {
            for (late in listOf(0L, 60_000L, maximumRing)) {
                val recovered = plan(state, nextAt = now - late)
                assertEquals(AlarmRules.RecoveryAction.REARM, recovered.action)
                assertEquals(now + 2_000L, recovered.nextAt)
                assertNull(recovered.event)
            }
        }
    }

    @Test fun oldScheduledOrSnoozedRingsResolveAsMissed() {
        for (state in listOf("scheduled", "snoozed")) {
            val recovered = plan(state, nextAt = now - maximumRing - 1L)
            assertEquals(AlarmRules.RecoveryAction.RESOLVE, recovered.action)
            assertEquals("missed", recovered.event)
        }
    }

    @Test fun interruptedRingingIsRearmedWithinItsOriginalSafetyWindow() {
        val recovered = plan("ringing", ringingSince = now - maximumRing + 1L)
        assertEquals(AlarmRules.RecoveryAction.REARM, recovered.action)
        assertEquals(now + 2_000L, recovered.nextAt)
        val started = now - 80_000L
        assertEquals(started, AlarmRules.ringingSinceAfterFire("ringing", started, now))
    }

    @Test fun ringingAtItsSafetyDeadlineTimesOutInsteadOfRestarting() {
        val recovered = plan("ringing", ringingSince = now - maximumRing)
        assertEquals(AlarmRules.RecoveryAction.RESOLVE, recovered.action)
        assertEquals("timed_out", recovered.event)
    }

    @Test fun foregroundRestoreDoesNotReplayAnAlreadyRingingAlarm() {
        assertEquals(AlarmRules.RecoveryAction.IGNORE, plan("ringing", skipRinging = true).action)
        assertEquals(AlarmRules.RecoveryAction.REARM, plan("snoozed", skipRinging = true).action)
    }

    @Test fun foregroundRestoreStillResolvesAnExpiredSavedRing() {
        val recovered = plan("ringing", ringingSince = now - maximumRing, skipRinging = true)
        assertEquals(AlarmRules.RecoveryAction.RESOLVE, recovered.action)
        assertEquals("timed_out", recovered.event)
    }

    @Test fun clockChangeRecomputesOnlyAnOrdinaryScheduledWallTime() {
        assertEquals(AlarmRules.RecoveryAction.NEXT_OCCURRENCE, plan(clockChanged = true).action)
        val preview = plan(clockChanged = true, preview = true)
        assertEquals(AlarmRules.RecoveryAction.REARM, preview.action)
        assertEquals(now + 60_000L, preview.nextAt)
        val snoozed = plan("snoozed", clockChanged = true)
        assertEquals(AlarmRules.RecoveryAction.REARM, snoozed.action)
        assertEquals(now + 60_000L, snoozed.nextAt)
    }

    @Test fun disabledAndResolvedAlarmsCannotBeResurrectedByBoot() {
        for (state in listOf("scheduled", "snoozed", "ringing")) {
            assertEquals(AlarmRules.RecoveryAction.IGNORE, plan(state, enabled = false).action)
        }
        for (state in listOf("disabled", "dismissed", "cancelled", "unknown")) {
            assertEquals(AlarmRules.RecoveryAction.IGNORE, plan(state).action)
        }
    }

    @Test fun ordinaryAndSnoozedRingsStartANewPlaybackWindowButBootDoesNot() {
        for (state in listOf("scheduled", "snoozed")) {
            assertEquals(now, AlarmRules.ringingSinceAfterFire(state, now - 50_000L, now))
        }
        assertEquals(now, AlarmRules.ringingSinceAfterFire("ringing", 0L, now))
        assertEquals(now - 50_000L, AlarmRules.ringingSinceAfterFire("ringing", now - 50_000L, now))
    }
}
