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
        oneShot: Boolean = false,
    ) = AlarmRules.recoveryPlan(enabled, state, nextAt, ringingSince, now, clockChanged, preview, skipRinging, oneShot)

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

    @Test fun oldUnstartedSchedulesAndPreviewSnoozesResolveAsMissed() {
        for (state in listOf("scheduled", "snoozed")) {
            val recovered = plan(state, nextAt = now - maximumRing - 1L, preview = state == "snoozed")
            assertEquals(AlarmRules.RecoveryAction.RESOLVE, recovered.action)
            assertEquals("missed", recovered.event)
        }
    }

    @Test fun interruptedRealRingingNeverExpiresAcrossReboot() {
        for (elapsed in listOf(maximumRing - 1L, maximumRing, 24 * 60 * 60_000L)) {
            val recovered = plan("ringing", ringingSince = now - elapsed)
            assertEquals(AlarmRules.RecoveryAction.REARM, recovered.action)
            assertEquals(now + 2_000L, recovered.nextAt)
            assertNull(recovered.event)
        }
        val started = now - 80_000L
        assertEquals(started, AlarmRules.ringingSinceAfterFire("ringing", started, now))
    }

    @Test fun previewAtItsSafetyDeadlineTimesOutInsteadOfRestarting() {
        val recovered = plan("ringing", ringingSince = now - maximumRing, preview = true)
        assertEquals(AlarmRules.RecoveryAction.RESOLVE, recovered.action)
        assertEquals("timed_out", recovered.event)
    }

    @Test fun foregroundRestoreDoesNotReplayAnAlreadyRingingAlarm() {
        assertEquals(AlarmRules.RecoveryAction.IGNORE, plan("ringing", skipRinging = true).action)
        assertEquals(AlarmRules.RecoveryAction.REARM, plan("snoozed", skipRinging = true).action)
    }

    @Test fun foregroundRestoreStillResolvesAnExpiredPreview() {
        val recovered = plan("ringing", ringingSince = now - maximumRing, skipRinging = true, preview = true)
        assertEquals(AlarmRules.RecoveryAction.RESOLVE, recovered.action)
        assertEquals("timed_out", recovered.event)
    }

    @Test fun clockChangeRecomputesOnlyAnOrdinaryScheduledWallTime() {
        assertEquals(AlarmRules.RecoveryAction.NEXT_OCCURRENCE, plan(clockChanged = true).action)
        val preview = plan(clockChanged = true, preview = true)
        assertEquals(AlarmRules.RecoveryAction.REARM, preview.action)
        assertEquals(now + 60_000L, preview.nextAt)
        val nap = plan(clockChanged = true, oneShot = true)
        assertEquals(AlarmRules.RecoveryAction.REARM, nap.action)
        assertEquals(now + 60_000L, nap.nextAt)
        val snoozed = plan("snoozed", clockChanged = true)
        assertEquals(AlarmRules.RecoveryAction.REARM, snoozed.action)
        assertEquals(now + 60_000L, snoozed.nextAt)
    }

    @Test fun lateRealSnoozeContinuesTheExistingWakeUp() {
        val recovered = plan("snoozed", nextAt = now - 24 * 60 * 60_000L)
        assertEquals(AlarmRules.RecoveryAction.REARM, recovered.action)
        assertEquals(now + 2_000L, recovered.nextAt)
        assertNull(recovered.event)
    }

    @Test fun realAndNapPlaybackHaveNoAutomaticStop() {
        for (id in listOf("morning", "nap")) {
            assertNull(AlarmRules.automaticStopDelay(id, now - maximumRing, now))
        }
        assertEquals(1L, AlarmRules.automaticStopDelay("preview:test", now - maximumRing, now))
        assertEquals(maximumRing - 60_000L, AlarmRules.automaticStopDelay("preview:test", now - 60_000L, now))
        assertEquals(maximumRing, AlarmRules.automaticStopDelay("preview:test", now + maximumRing, now))
        assertEquals(AlarmRules.RecoveryAction.IGNORE,
            plan("ringing", ringingSince = now - 24 * 60 * 60_000L, skipRinging = true).action)
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
