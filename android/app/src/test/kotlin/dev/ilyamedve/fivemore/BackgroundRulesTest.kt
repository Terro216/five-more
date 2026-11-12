package dev.ilyamedve.fivemore

import org.junit.Assert.*
import org.junit.Test

class BackgroundRulesTest {
    @Test fun framingSurvivesValidInputAndBoundsInvalidOrLegacyValues() {
        val chosen = mapOf("x" to 0.1, "y" to 0.8, "zoom" to 2.5, "turns" to 3)
        assertEquals(chosen, BackgroundRules.frame(chosen))
        assertEquals(mapOf("x" to .5, "y" to .5, "zoom" to 1.0, "turns" to 0), BackgroundRules.frame(null))
        assertEquals(mapOf("x" to 0.0, "y" to 1.0, "zoom" to 1.0, "turns" to 3), BackgroundRules.frame(mapOf("x" to -1, "y" to 5, "zoom" to Double.NaN, "turns" to 12)))
        assertEquals(4.0, BackgroundRules.frame(mapOf("zoom" to 900))["zoom"])
    }
    @Test fun onlyLocalGeneratedNamesAreAccepted() {
        assertTrue(BackgroundRules.validName("00000000-0000-4000-8000-000000000001.jpg"))
        for (value in listOf("", "../photo.jpg", "/photo.jpg", "https://example.test/photo.jpg", "00000000-0000-4000-8000-000000000001.jpg/../x")) {
            assertFalse(value, BackgroundRules.validName(value))
        }
    }

    @Test fun decodingIsBoundedForLargePortraitLandscapeAndExtremeDimensions() {
        for ((width, height) in listOf(1 to 1, 1200 to 1600, 4032 to 3024, 3024 to 4032, Int.MAX_VALUE to 1)) {
            val sample = BackgroundRules.sampleSize(width, height)
            assertTrue(sample > 0 && sample and (sample - 1) == 0)
            assertTrue(maxOf(width, height).toLong() <= 1600L * sample)
            if (sample > 1) assertTrue(maxOf(width, height).toLong() > 1600L * (sample / 2))
        }
    }

    @Test fun invalidImageDimensionsAreRejectedBeforeDecoding() {
        for ((width, height) in listOf(0 to 10, 10 to 0, -1 to -1)) {
            assertThrows(IllegalArgumentException::class.java) { BackgroundRules.sampleSize(width, height) }
        }
    }
}
