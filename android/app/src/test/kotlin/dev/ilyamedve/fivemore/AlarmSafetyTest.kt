package dev.ilyamedve.fivemore

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test

class AlarmSafetyTest {
    @Test fun backgroundClockRecoveryStopsAudioAfterResolvingTheLastExpiredPreview() {
        val now = 10_000_000L
        val recovery = AlarmRules.recoveryPlan(
            enabled = true, state = "ringing", nextAt = 0L,
            ringingSince = now - 16 * 60_000L, now = now,
            preview = true, clockChanged = true,
        )
        assertEquals(AlarmRules.RecoveryAction.RESOLVE, recovery.action)
        assertEquals("timed_out", recovery.event)
        val actions = mutableListOf<String>()
        // Once resolve() persisted the terminal state, no ringing record remains.
        AlarmSafety.stopRecoveredPlaybackIfIdle(
            hasRingingAlarm = { actions.add("read-current-state"); false },
            stopPlayback = { actions.add("stop-service") },
        )
        assertEquals(listOf("read-current-state", "stop-service"), actions)
    }

    @Test fun resolvingOneExpiredRingDoesNotSilenceAnotherRingingOccurrence() {
        var stopped = false
        AlarmSafety.stopRecoveredPlaybackIfIdle(
            hasRingingAlarm = { true },
            stopPlayback = { stopped = true },
        )
        assertFalse(stopped)
    }

    @Test fun recoveryReadFailureIsNotTreatedAsAnIdleAlarmEngine() {
        var stopped = false
        assertThrows(IllegalStateException::class.java) {
            AlarmSafety.stopRecoveredPlaybackIfIdle(
                hasRingingAlarm = { throw IllegalStateException("unreadable store") },
                stopPlayback = { stopped = true },
            )
        }
        assertFalse(stopped)
    }

    @Test fun persistedDismissalDoesNotStopTheNextQueuedAlarm() {
        var fallbackCalled = false
        val result = AlarmSafety.resolveOrSilence(
            operation = { "next-alarm-running" },
            silenceWithoutPersistence = { fallbackCalled = true },
            failure = { "failed" },
        )
        assertEquals("next-alarm-running", result)
        assertFalse(fallbackCalled)
    }

    @Test fun storageFailureSilencesBeforeReturningTruthfulFailure() {
        val actions = mutableListOf<String>()
        val result = AlarmSafety.resolveOrSilence(
            operation = { actions.add("write"); throw IllegalStateException("disk full") },
            silenceWithoutPersistence = { actions.add("silence") },
            failure = { error -> actions.add("failure"); error.message },
        )
        assertEquals(listOf("write", "silence", "failure"), actions)
        assertEquals("disk full", result)
    }

    @Test fun failedReadAlsoTakesEmergencyPathWithoutRetryingStorage() {
        var reads = 0
        var silenceCount = 0
        val result = AlarmSafety.resolveOrSilence(
            operation = { reads++; throw IllegalArgumentException("invalid stored data") },
            silenceWithoutPersistence = { silenceCount++ },
            failure = { false },
        )
        assertFalse(result)
        assertEquals(1, reads)
        assertEquals(1, silenceCount)
    }
}
