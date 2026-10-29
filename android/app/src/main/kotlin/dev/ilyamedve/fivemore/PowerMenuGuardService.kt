package dev.ilyamedve.fivemore

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.ComponentName
import android.content.Context
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityManager
import android.view.accessibility.AccessibilityWindowInfo

object PowerMenuProtection {
    private fun preferences(context: Context) = context.createDeviceProtectedStorageContext()
        .getSharedPreferences("five_more_protection", Context.MODE_PRIVATE)

    fun requested(context: Context): Boolean = preferences(context).getBoolean("powerMenu", false)

    fun setRequested(context: Context, enabled: Boolean) {
        check(preferences(context).edit().putBoolean("powerMenu", enabled).commit()) {
            "Cannot save power menu preference"
        }
        if (!enabled) PowerMenuGuardService.disable()
    }

    fun component(context: Context) = ComponentName(context, PowerMenuGuardService::class.java)

    fun active(context: Context): Boolean? = runCatching { requested(context) &&
        context.getSystemService(AccessibilityManager::class.java)
            .getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK)
            .any { service ->
                val info = service.resolveInfo.serviceInfo
                ComponentName(info.packageName, info.name) == component(context)
            }
    }.getOrNull()
}

/** Uses only system window metadata. No nodes, text, gestures, screenshots or network. */
class PowerMenuGuardService : AccessibilityService() {
    override fun onServiceConnected() {
        connected = this
        if (!PowerMenuProtection.requested(this)) disableSelf()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event?.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED ||
            event.packageName?.toString() != "com.android.systemui") return
        try {
            if (!PowerMenuProtection.requested(this)) return
            val alarm = AlarmEngine(this).ringing() ?: return
            if (!PowerMenuRules.realRinging(alarm.optString("id"), alarm.optString("state"), alarm.optBoolean("enabled"))) return
            // A queued event may refer to a window that has already disappeared.
            // Match the currently focused system window before issuing Back.
            val window = windows.firstOrNull { it.id == event.windowId } ?: return
            if (PowerMenuRules.isPowerMenu(
                    event.packageName?.toString(), window.title?.toString(),
                    window.type == AccessibilityWindowInfo.TYPE_SYSTEM, window.isFocused,
                )) {
                performGlobalAction(GLOBAL_ACTION_BACK)
            }
        } catch (_: Exception) {
            // Storage/OS failure must never intercept another screen or disable emergency exit.
        }
    }

    override fun onInterrupt() = Unit

    override fun onDestroy() {
        if (connected === this) connected = null
        super.onDestroy()
    }

    companion object {
        private var connected: PowerMenuGuardService? = null
        fun disable() { connected?.disableSelf() }
    }
}
