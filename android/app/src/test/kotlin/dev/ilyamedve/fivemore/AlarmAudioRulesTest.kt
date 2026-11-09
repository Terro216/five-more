package dev.ilyamedve.fivemore

import org.junit.Assert.*
import org.junit.Test

class AlarmAudioRulesTest {
    @Test fun intervalUsesMonotonicTimeAndCannotBeExtendedByAnotherTap() {
        assertEquals(30_000L, AlarmAudioRules.remaining(100L, 30_100L, 8, 8))
        assertFalse(AlarmAudioRules.canQuiet(1, 1L))
        assertTrue(AlarmAudioRules.canQuiet(1, 0L))
        assertFalse(AlarmAudioRules.canQuiet(2, 0L))
    }
    @Test fun restartInSameBootKeepsDeadlineButRebootRestoresSound() {
        assertEquals(15_000L, AlarmAudioRules.remaining(15_100L, 30_100L, 8, 8))
        assertEquals(0L, AlarmAudioRules.remaining(100L, 30_100L, 8, 9))
        assertEquals(0L, AlarmAudioRules.remaining(100L, 30_100L, -1, -1))
    }
    @Test fun callWinsOverRampAndQuietWithoutChangingBudget() {
        assertEquals(0f, AlarmAudioRules.level(1000, 0, 30000, null, true), 0.001f)
        assertEquals(0.4f, AlarmAudioRules.level(1000, 0, 30000, null, false), 0.001f)
        assertEquals(1f, AlarmAudioRules.level(1000, 0, 0, null, false), 0.001f)
        assertEquals(0.5f, AlarmAudioRules.level(1000, 0, 0, 1250, false), 0.001f)
    }
}
