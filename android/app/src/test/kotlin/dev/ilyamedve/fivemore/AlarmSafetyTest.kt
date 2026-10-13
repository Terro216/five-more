package dev.ilyamedve.fivemore

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class AlarmSafetyTest {
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
