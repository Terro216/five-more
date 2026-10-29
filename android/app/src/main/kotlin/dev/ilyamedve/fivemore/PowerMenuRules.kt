package dev.ilyamedve.fivemore

/** Deliberately narrow: an unfamiliar OEM window is left alone. */
object PowerMenuRules {
    fun realRinging(id: String, state: String, enabled: Boolean): Boolean =
        enabled && id.isNotBlank() && !AlarmRules.isPreviewId(id) && state == "ringing"

    fun isPowerMenu(packageName: String?, title: String?, systemWindow: Boolean, focused: Boolean): Boolean =
        packageName == "com.android.systemui" && systemWindow && focused && title == "ActionsDialog"
}
