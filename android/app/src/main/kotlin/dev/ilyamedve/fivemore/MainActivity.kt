package dev.ilyamedve.fivemore

import android.Manifest
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        if (AlarmEngine(this).ringing() != null) enableWakeScreen()
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (AlarmEngine(this).ringing() != null) enableWakeScreen()
    }

    private fun enableWakeScreen() {
        updateWakeScreen(true)
    }

    private fun updateWakeScreen(ringing: Boolean) {
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(ringing)
            setTurnScreenOn(ringing)
        } else {
            @Suppress("DEPRECATION")
            if (ringing) window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
            else window.clearFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        }
        if (ringing) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "five_more/alarm").setMethodCallHandler { call, result ->
            try {
                val engine = AlarmEngine(this)
                val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                val id = args["id"] as? String ?: ""
                when (call.method) {
                    "schedule" -> result.success(engine.schedule(args))
                    "cancel" -> result.success(engine.cancel(id))
                    "snooze" -> result.success(engine.snooze(id))
                    "dismiss" -> result.success(engine.dismiss(id, emergency = args["emergency"] == true))
                    "status" -> result.success(engine.status())
                    "getRingingAlarm" -> {
                        val ringing = engine.getRingingAlarm()
                        updateWakeScreen(ringing != null)
                        result.success(ringing)
                    }
                    "drainEvents" -> result.success(AlarmStore(this).drainEvents())
                    "ackEvents" -> {
                        val ids = (args["eventIds"] as? List<*>)?.filterIsInstance<String>()?.toSet() ?: emptySet()
                        AlarmStore(this).ackEvents(ids)
                        result.success(mapOf("ok" to true))
                    }
                    "testAlarm" -> result.success(engine.testAlarm(id, args["delaySeconds"]))
                    "cancelTestAlarm" -> result.success(engine.cancelTestAlarm(id))
                    "requestPermissions" -> {
                        val opened = requestPermission(args["target"] as? String)
                        result.success(if (opened) engine.status() else engine.status() + mapOf(
                            "ok" to false, "error" to "settings_unavailable",
                        ))
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("native_alarm_error", error.message ?: "Alarm operation failed", null)
            }
        }
    }

    /** An explicit checklist row opens only its own system setting, never another permission. */
    private fun requestPermission(target: String?): Boolean {
        val notifications = getSystemService(NotificationManager::class.java)
        return when (target) {
            null -> { requestNextPermission(); true }
            "notifications" -> {
                if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                    val preferences = getSharedPreferences("five_more_permissions", MODE_PRIVATE)
                    if (!preferences.getBoolean("notification_requested", false) || shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)) {
                        preferences.edit().putBoolean("notification_requested", true).apply()
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 501)
                        return true
                    }
                }
                val channel = notifications.getNotificationChannel(AlarmRingingService.CHANNEL_ID)
                if (channel != null && channel.importance == NotificationManager.IMPORTANCE_NONE) openChannelSettings()
                else openSettings(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
            }
            "exactAlarms" -> {
                if (Build.VERSION.SDK_INT >= 31) openSettings(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:$packageName")))
                else openSettings(appDetailsIntent())
            }
            "fullScreenIntent" -> {
                val channel = notifications.getNotificationChannel(AlarmRingingService.CHANNEL_ID)
                if (channel != null && channel.importance < NotificationManager.IMPORTANCE_HIGH) openChannelSettings()
                else if (Build.VERSION.SDK_INT >= 34) openSettings(Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:$packageName")))
                else openChannelSettings()
            }
            "battery" -> openSettings(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            "alarmVolume" -> openSettings(Intent(Settings.ACTION_SOUND_SETTINGS))
            else -> false
        }
    }

    private fun openChannelSettings(): Boolean = openSettings(
        Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            .putExtra(Settings.EXTRA_CHANNEL_ID, AlarmRingingService.CHANNEL_ID)
    )

    private fun appDetailsIntent() = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))

    private fun openSettings(intent: Intent): Boolean {
        try {
            startActivity(intent)
            return true
        } catch (_: ActivityNotFoundException) {
            // OEM settings apps may not provide a standard panel. The app page is a safe fallback.
        } catch (_: SecurityException) { }
        return try {
            startActivity(appDetailsIntent())
            true
        } catch (_: Exception) { false }
    }

    override fun onResume() {
        super.onResume()
        val engine = AlarmEngine(this)
        engine.reschedule(skipRinging = true)
        val ringing = engine.ringing() != null
        updateWakeScreen(ringing)
        if (ringing) {
            startForegroundService(Intent(this, AlarmRingingService::class.java))
        }
    }

    /** One explicit system step at a time; Flutter rechecks status when it resumes. */
    private fun requestNextPermission() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            val preferences = getSharedPreferences("five_more_permissions", MODE_PRIVATE)
            if (preferences.getBoolean("notification_requested", false) && !shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)) {
                startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
                return
            }
            preferences.edit().putBoolean("notification_requested", true).apply()
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 501)
            return
        }
        if (Build.VERSION.SDK_INT >= 31 && !AlarmEngine(this).canSchedule()) {
            startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:$packageName")))
            return
        }
        val notifications = getSystemService(NotificationManager::class.java)
        if (!AlarmEngine(this).notificationsEnabled()) {
            startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
            return
        }
        val channel = notifications.getNotificationChannel(AlarmRingingService.CHANNEL_ID)
        if (channel != null && channel.importance < NotificationManager.IMPORTANCE_HIGH) {
            startActivity(Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                .putExtra(Settings.EXTRA_CHANNEL_ID, AlarmRingingService.CHANNEL_ID))
            return
        }
        if (Build.VERSION.SDK_INT >= 34 && !notifications.canUseFullScreenIntent()) {
            startActivity(Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:$packageName")))
        }
    }
}
