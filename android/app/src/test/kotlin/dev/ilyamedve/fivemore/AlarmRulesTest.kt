package dev.ilyamedve.fivemore

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.ZoneId
import java.util.TimeZone

class AlarmRulesTest {
    private fun at(value: String): Long = Instant.parse(value).toEpochMilli()
    private val utc = TimeZone.getTimeZone("UTC")

    @Test fun legacyChallengeConfigurationDoesNotOptIntoEscalation() {
        val defaults = AlarmRules.challengeOptions(emptyMap<String, Any>())!!
        assertEquals("math", defaults.kind)
        assertEquals("medium", defaults.difficulty)
        assertFalse(defaults.escalateOnSnooze)
        assertFalse(defaults.moveSnoozeButton)
        val legacy = AlarmRules.challengeOptions(mapOf("challengeKind" to "memory", "difficulty" to "hard"))!!
        assertEquals("memory", legacy.kind)
        assertEquals("hard", legacy.difficulty)
        assertFalse(legacy.escalateOnSnooze)
        assertFalse(legacy.moveSnoozeButton)
    }

    @Test fun configuredChallengeKeepsBaseDifficultyForEverySupportedKind() {
        for (kind in listOf("math", "memory", "stroop", "sequence", "mirror", "captcha", "qr", "shake", "maze", "flags", "mixed")) {
            for (escalate in listOf(false, true)) {
                val options = AlarmRules.challengeOptions(mapOf(
                    "challengeKind" to kind, "difficulty" to "easy", "escalateOnSnooze" to escalate,
                ))!!
                assertEquals(kind, options.kind)
                assertEquals("easy", options.difficulty)
                assertEquals(escalate, options.escalateOnSnooze)
            }
        }
    }

    @Test fun extremeDifficultySurvivesNativeConfigurationWithoutChangingLegacyLevels() {
        val extreme = AlarmRules.challengeOptions(mapOf("challengeKind" to "maze", "difficulty" to "extreme"))!!
        assertEquals("extreme", extreme.difficulty)
        assertEquals("maze", extreme.kind)
        assertFalse(extreme.escalateOnSnooze)
        assertEquals("hard", AlarmRules.challengeOptions(mapOf("difficulty" to "hard"))!!.difficulty)
    }

    @Test fun escalationRejectsTruthyStringsNumbersAndExplicitNull() {
        for (value in listOf("true", "false", 1, 0, 1L, 1.0, null)) {
            assertNull(AlarmRules.challengeOptions(mapOf("escalateOnSnooze" to value)))
        }
    }

    @Test fun movingSnoozeRequiresAnActualBooleanAndKeepsTheSavedChoice() {
        for (moving in listOf(false, true)) {
            val options = AlarmRules.challengeOptions(mapOf("moveSnoozeButton" to moving))!!
            assertEquals(moving, options.moveSnoozeButton)
        }
        for (value in listOf("true", "false", 1, 0, 1L, 1.0, null)) {
            assertNull(AlarmRules.challengeOptions(mapOf("moveSnoozeButton" to value)))
            assertFalse(AlarmRules.challengeOptions(mapOf("moveSnoozeButton" to value), fromStoredConfiguration = true)!!.moveSnoozeButton)
        }
    }

    @Test fun savedTextChallengeAndMovingSnoozeRemainAvailableInPreview() {
        for (kind in listOf("mirror", "captcha")) {
            val preview = AlarmRules.challengeOptions(mapOf(
                "challengeKind" to kind, "difficulty" to "hard",
                "escalateOnSnooze" to true, "moveSnoozeButton" to true,
            ), fromStoredConfiguration = true)!!
            assertEquals(kind, preview.kind)
            assertEquals("hard", preview.difficulty)
            assertTrue(preview.escalateOnSnooze)
            assertTrue(preview.moveSnoozeButton)
        }
    }

    @Test fun unknownOrCoercedChallengeOptionsAreRejectedBeforeScheduling() {
        for (value in listOf("", "unknown", "Sequence", true, 1, null)) {
            assertNull(AlarmRules.challengeOptions(mapOf("challengeKind" to value)))
        }
        for (value in listOf("", "expert", "Hard", true, 1, null)) {
            assertNull(AlarmRules.challengeOptions(mapOf("difficulty" to value)))
        }
    }

    @Test fun legacyPreviewFallbackDoesNotRejectAnExistingAlarmOrCoerceEscalation() {
        val legacy = mapOf("challengeKind" to "old-unknown-kind", "difficulty" to "hard", "escalateOnSnooze" to "true")
        assertNull(AlarmRules.challengeOptions(legacy))
        val preview = AlarmRules.challengeOptions(legacy, fromStoredConfiguration = true)!!
        assertEquals("math", preview.kind)
        assertEquals("hard", preview.difficulty)
        assertFalse(preview.escalateOnSnooze)
    }

    @Test fun testDelayAcceptsDefaultAndInclusiveIntegerBounds() {
        assertEquals(5, AlarmRules.testDelaySeconds(null))
        assertEquals(5, AlarmRules.testDelaySeconds(5))
        assertEquals(30, AlarmRules.testDelaySeconds(30L))
        assertEquals(60, AlarmRules.testDelaySeconds(60))
    }

    @Test fun testDelayRejectsOutOfRangeOrCoercedValues() {
        for (value in listOf(0, 4, 61, -5, Long.MAX_VALUE, 5.0, 5.9, "30", true)) {
            assertNull(AlarmRules.testDelaySeconds(value))
        }
    }

    @Test fun previewCancellationGuardRejectsRealOrEmptyIdentifiers() {
        assertTrue(AlarmRules.isPreviewId("preview:temporary-id"))
        for (id in listOf("", "preview:", "ordinary-id", "not-preview:temporary-id", " preview:temporary-id")) {
            assertFalse(AlarmRules.isPreviewId(id))
        }
    }

    @Test fun oneShotBeforeSelectedTimeUsesToday() {
        assertEquals(at("2026-10-13T07:30:00Z"), AlarmRules.nextOccurrence(7, 30, emptySet(), at("2026-10-13T07:29:59Z"), utc))
    }

    @Test fun exactCurrentTimeUsesTomorrowInsteadOfImmediateDuplicate() {
        assertEquals(at("2026-10-14T07:30:00Z"), AlarmRules.nextOccurrence(7, 30, emptySet(), at("2026-10-13T07:30:00Z"), utc))
    }

    @Test fun weekdaySelectionSkipsWeekend() {
        assertEquals(at("2026-10-19T07:30:00Z"), AlarmRules.nextOccurrence(7, 30, setOf(1, 2, 3, 4, 5), at("2026-10-16T09:00:00Z"), utc))
    }

    @Test fun onlyTodaySelectedCanAdvanceFullWeek() {
        assertEquals(at("2026-10-20T07:30:00Z"), AlarmRules.nextOccurrence(7, 30, setOf(2), at("2026-10-13T08:00:00Z"), utc))
    }

    @Test fun springTransitionKeepsWallClockHourAcrossShortDay() {
        val now = at("2026-03-28T08:00:00Z")
        val next = AlarmRules.nextOccurrence(7, 30, emptySet(), now, TimeZone.getTimeZone("Europe/Berlin"))
        assertEquals(at("2026-03-29T05:30:00Z"), next)
    }

    @Test fun nonexistentSpringTimeMovesForwardInLocalCalendar() {
        val next = AlarmRules.nextOccurrence(2, 30, emptySet(), at("2026-03-28T23:00:00Z"), TimeZone.getTimeZone("Europe/Berlin"))
        val local = Instant.ofEpochMilli(next).atZone(ZoneId.of("Europe/Berlin"))
        assertEquals(29, local.dayOfMonth)
        assertEquals(3, local.hour)
        assertEquals(30, local.minute)
    }

    @Test fun autumnOccurrenceDoesNotRescheduleSameCompletedOccurrence() {
        val zone = TimeZone.getTimeZone("Europe/Berlin")
        val first = AlarmRules.nextOccurrence(2, 30, emptySet(), at("2026-10-24T22:00:00Z"), zone)
        val next = AlarmRules.nextOccurrence(2, 30, emptySet(), first + 1, zone)
        val local = Instant.ofEpochMilli(next).atZone(ZoneId.of("Europe/Berlin"))
        assertEquals(26, local.dayOfMonth)
        assertEquals(2, local.hour)
    }

    @Test fun snoozingConsumesPersistedBudgetAndStopsAtLimit() {
        val first = AlarmRules.nextSnooze(1_000L, 0, 5, 3)!!
        assertEquals(1, first.used)
        assertEquals(301_000L, first.nextAt)
        val resumed = AlarmRules.nextSnooze(first.nextAt, first.used, 5, 3)!!
        val last = AlarmRules.nextSnooze(resumed.nextAt, resumed.used, 5, 3)!!
        assertEquals(3, last.used)
        assertEquals(901_000L, last.nextAt)
        assertNull(AlarmRules.nextSnooze(last.nextAt, last.used, 5, 3))
    }

    @Test fun disabledSnoozeAndCorruptValuesCannotGrantExtraTime() {
        assertNull(AlarmRules.nextSnooze(0, 0, 5, 0))
        assertNull(AlarmRules.nextSnooze(0, -1, 5, 3))
        assertNull(AlarmRules.nextSnooze(0, 0, 0, 3))
        assertNull(AlarmRules.nextSnooze(0, 10, 5, 3))
    }
}
