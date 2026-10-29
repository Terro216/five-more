package dev.ilyamedve.fivemore

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PowerMenuRulesTest {
    @Test fun onlyAnEnabledRealRingingOccurrenceQualifies() {
        assertTrue(PowerMenuRules.realRinging("morning", "ringing", true))
        assertTrue(PowerMenuRules.realRinging("nap", "ringing", true))
        for (state in listOf("snoozed", "scheduled", "dismissed", "disabled")) {
            assertFalse(PowerMenuRules.realRinging("morning", state, true))
        }
        assertFalse(PowerMenuRules.realRinging("preview:test", "ringing", true))
        assertFalse(PowerMenuRules.realRinging("morning", "ringing", false))
        assertFalse(PowerMenuRules.realRinging("", "ringing", true))
    }

    @Test fun unknownWindowsPermissionsCallsAndUnfocusedEventsAreNeverClosed() {
        assertTrue(PowerMenuRules.isPowerMenu("com.android.systemui", "ActionsDialog", true, true))
        for (pkg in listOf(null, "android", "com.android.settings", "com.android.dialer", "dev.ilyamedve.fivemore")) {
            assertFalse(PowerMenuRules.isPowerMenu(pkg, "ActionsDialog", true, true))
        }
        for (title in listOf(null, "", "NotificationShade", "VolumeDialog", "Emergency", "Permission", "Power off")) {
            assertFalse(PowerMenuRules.isPowerMenu("com.android.systemui", title, true, true))
        }
        assertFalse(PowerMenuRules.isPowerMenu("com.android.systemui", "ActionsDialog", false, true))
        assertFalse(PowerMenuRules.isPowerMenu("com.android.systemui", "ActionsDialog", true, false))
    }
}
