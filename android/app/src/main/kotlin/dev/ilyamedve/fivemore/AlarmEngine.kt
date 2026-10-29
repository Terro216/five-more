package dev.ilyamedve.fivemore

import android.app.AlarmManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.media.AudioManager
import android.os.Build
import android.os.PowerManager
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** The native engine, not Flutter, owns every active occurrence and its snooze budget. */
class AlarmEngine(private val context: Context) {
    private val store = AlarmStore(context)
    private val manager = context.getSystemService(AlarmManager::class.java)
    private data class TestMetadata(val sourceId: String, val startedAt: Long, val dueAt: Long)

    fun status(): Map<String, Any?> {
        val alarms = store.alarms()
        val result = mutableMapOf<String, Any?>(
            "platform" to "android",
            "supported" to true,
            "exactAlarms" to canSchedule(),
            "notifications" to notificationsEnabled(),
            "fullScreenIntent" to fullScreenAvailable(),
            "batteryOptimized" to !context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName),
            "alarmVolume" to context.getSystemService(AudioManager::class.java).getStreamVolume(AudioManager.STREAM_ALARM),
            "alarmMaxVolume" to context.getSystemService(AudioManager::class.java).getStreamMaxVolume(AudioManager.STREAM_ALARM),
            "deviceAdminActive" to AlarmDeviceAdminReceiver.active(context),
            "powerMenuGuardActive" to PowerMenuProtection.active(context),
            "bootRecoverySupported" to true,
            "recoveryError" to (recoveryFailure ?: store.recoveryError),
            "scheduledCount" to alarms.count { it.optBoolean("enabled") },
            "alarms" to alarms.map { it.toMap() },
            "error" to safetyError,
        )
        alarms.firstNotNullOfOrNull { alarm ->
            val id = alarm.optString("id")
            val source = alarm.optString("testSourceId")
            val started = alarm.optLong("testStartedAt")
            val due = alarm.optLong("testDueAt")
            if (!AlarmRules.isPreviewId(id) || !alarm.optBoolean("enabled") ||
                alarm.optString("state") !in listOf("scheduled", "ringing", "snoozed") ||
                source.isBlank() || source.startsWith("preview:") || started <= 0 || due < started) null
            else mapOf("sourceAlarmId" to source, "previewAlarmId" to id, "startedAt" to started, "dueAt" to due)
        }?.let { result["activeTest"] = it }
        return result
    }

    fun canSchedule(): Boolean = Build.VERSION.SDK_INT < 31 || manager.canScheduleExactAlarms()

    fun notificationsEnabled(): Boolean {
        val notifications = context.getSystemService(NotificationManager::class.java)
        val channel = notifications.getNotificationChannel(AlarmRingingService.CHANNEL_ID)
        return notifications.areNotificationsEnabled() && (channel == null || channel.importance != NotificationManager.IMPORTANCE_NONE)
    }

    fun fullScreenAvailable(): Boolean {
        val notifications = context.getSystemService(NotificationManager::class.java)
        val channel = notifications.getNotificationChannel(AlarmRingingService.CHANNEL_ID)
        return (Build.VERSION.SDK_INT < 34 || notifications.canUseFullScreenIntent()) &&
            (channel == null || channel.importance >= NotificationManager.IMPORTANCE_HIGH)
    }

    fun schedule(arguments: Map<*, *>): Map<String, Any?> = scheduleInternal(arguments)

    private fun scheduleInternal(arguments: Map<*, *>, test: TestMetadata? = null): Map<String, Any?> {
        val id = arguments["id"] as? String ?: return fail("invalid_id")
        if (id.isBlank() || id.length > 128) return fail("invalid_id")
        if (test != null && (!AlarmRules.isPreviewId(id) || test.dueAt <= System.currentTimeMillis())) return fail("invalid_test_delay")
        val old = store.get(id)
        if (old != null && old.optString("state") in listOf("ringing", "snoozed")) return fail("alarm_active")
        val hour = (arguments["hour"] as? Number)?.toInt() ?: return fail("invalid_hour")
        val minute = (arguments["minute"] as? Number)?.toInt() ?: return fail("invalid_minute")
        val snoozeMinutes = (arguments["snoozeMinutes"] as? Number)?.toInt() ?: 5
        val maxSnoozes = (arguments["maxSnoozes"] as? Number)?.toInt() ?: 3
        val budget = (arguments["snoozeBudgetMinutes"] as? Number)?.toInt() ?: maxSnoozes * snoozeMinutes
        val ramp = (arguments["volumeRampSeconds"] as? Number)?.toInt() ?: 10
        if (budget !in 0..300 || ramp !in setOf(0, 10, 30, 60)) return fail("invalid_schedule")
        val weekdays = (arguments["weekdays"] as? List<*>)?.mapNotNull { (it as? Number)?.toInt() } ?: emptyList()
        if (hour !in 0..23 || minute !in 0..59 || snoozeMinutes !in 1..30 || maxSnoozes !in 0..10 || weekdays.any { it !in 1..7 }) return fail("invalid_schedule")
        val challenge = AlarmRules.challengeOptions(arguments, fromStoredConfiguration = test != null)
            ?: return fail("invalid_challenge")
        val enabled = arguments["enabled"] as? Boolean ?: true
        val oneShotAt = (arguments["oneShotAt"] as? Number)?.toLong() ?: 0L
        if (test == null && enabled && oneShotAt != 0L && (oneShotAt <= System.currentTimeMillis() || weekdays.isNotEmpty())) return fail("invalid_schedule")
        val order = (arguments["mixOrder"] as? List<*>)?.filterIsInstance<String>() ?: emptyList()
        if (order.size > 12 || order.any { it !in setOf("math", "memory", "stroop", "sequence", "mirror", "captcha", "qr", "shake", "maze", "flags") }) return fail("invalid_challenge")
        val qr = (arguments["qrValue"] as? String ?: "").take(2048)
        if ((challenge.kind == "qr" || (challenge.kind == "mixed" && "qr" in order)) && qr.isBlank()) return fail("invalid_challenge")
        val sound = arguments["sound"] as? String ?: "system"
        try { ExtrasBridge.soundUri(context, sound) } catch (_: Exception) { return fail("sound_unavailable", "Мелодия недоступна. Выбери её снова.") }
        if (enabled && !canSchedule()) return fail("exact_alarm_permission")
        val alarm = JSONObject()
            .put("id", id).put("title", (arguments["title"] as? String ?: "Ещё пять").take(160))
            .put("hour", hour).put("minute", minute).put("weekdays", JSONArray(weekdays.distinct()))
            .put("enabled", enabled).put("snoozeMinutes", snoozeMinutes).put("maxSnoozes", maxSnoozes)
            .put("snoozeBudgetMinutes", budget).put("snoozedMinutes", 0).put("volumeRampSeconds", ramp)
            .put("armedAt", (arguments["armedAt"] as? Number)?.toLong() ?: 0L)
            .put("challengeKind", challenge.kind).put("difficulty", challenge.difficulty)
            .put("escalateOnSnooze", challenge.escalateOnSnooze)
            .put("moveSnoozeButton", challenge.moveSnoozeButton)
            .put("oneShotAt", if (test == null) oneShotAt else 0L)
            .put("mixOrder", JSONArray(order)).put("qrValue", qr)
            .put("sound", sound).put("soundLabel", (arguments["soundLabel"] as? String ?: "Системный будильник").take(80))
            .put("snoozesUsed", 0).put("occurrenceId", UUID.randomUUID().toString())
            .put("state", if (enabled) "scheduled" else "disabled")
        val nextAt = if (enabled) {
            test?.dueAt ?: if (oneShotAt > 0) oneShotAt else nextOccurrence(alarm)
        } else 0L
        alarm.put("nextAt", nextAt)
        if (test != null) {
            alarm.put("testSourceId", test.sourceId)
                .put("testStartedAt", test.startedAt)
                .put("testDueAt", test.dueAt)
        }
        store.put(alarm)
        try {
            if (enabled) arm(alarm) else cancelPending(id)
        } catch (error: Exception) {
            if (old == null) {
                store.remove(id)
                cancelPending(id)
            } else {
                store.put(old)
                // FLAG_UPDATE_CURRENT may already have replaced the pending intent's extras.
                if (old.optBoolean("enabled") && canSchedule()) {
                    try { arm(old) } catch (_: Exception) { }
                }
            }
            return fail("schedule_failed", error.message)
        }
        silencedAlarmIds.remove(id)
        return success(alarm)
    }

    /** Disable a schedule. An already ringing alarm must be resolved through the wake-up screen. */
    fun cancel(id: String): Map<String, Any?> {
        val alarm = store.get(id) ?: return mapOf("ok" to true)
        if (alarm.optString("state") in listOf("ringing", "snoozed")) return fail("alarm_active")
        cancelPending(id)
        alarm.put("enabled", false).put("state", "disabled").put("nextAt", 0L)
        store.put(alarm)
        return success(alarm)
    }

    fun snooze(id: String, minutes: Int? = null): Map<String, Any?> {
        val alarm = store.get(id) ?: return fail("not_found")
        if (alarm.optString("state") != "ringing") return fail("not_ringing")
        val budget = alarm.optInt("snoozeBudgetMinutes", alarm.optInt("maxSnoozes", 3) * alarm.optInt("snoozeMinutes", 5))
        val spent = alarm.optInt("snoozedMinutes", alarm.optInt("snoozesUsed") * alarm.optInt("snoozeMinutes", 5))
        val chosen = minutes ?: minOf(alarm.optInt("snoozeMinutes", 5), budget - spent)
        val snooze = AlarmRules.nextBudgetSnooze(System.currentTimeMillis(), alarm.optInt("snoozesUsed"), spent, chosen, budget)
            ?: return fail("snooze_limit")
        if (!canSchedule()) return fail("exact_alarm_permission")
        val previous = JSONObject(alarm.toString())
        alarm.put("snoozesUsed", snooze.used).put("snoozedMinutes", snooze.totalMinutes)
            .put("state", "snoozed")
            .put("nextAt", snooze.nextAt)
        store.put(alarm)
        try {
            arm(alarm)
        } catch (error: Exception) {
            store.put(previous)
            return fail("schedule_failed", error.message)
        }
        store.event(alarm, "snoozed")
        refreshService()
        return success(alarm)
    }

    fun dismiss(id: String, emergency: Boolean = false, timedOut: Boolean = false): Map<String, Any?> {
        if (emergency || timedOut) {
            return AlarmSafety.resolveOrSilence(
                operation = { dismissPersisted(id, emergency, timedOut) },
                silenceWithoutPersistence = { silenceAfterPersistenceFailure(id) },
                failure = { fail("emergency_state_not_saved", it.message) },
            )
        }
        return dismissPersisted(id, emergency = false, timedOut = false)
    }

    private fun dismissPersisted(id: String, emergency: Boolean, timedOut: Boolean): Map<String, Any?> {
        val alarm = store.get(id) ?: return fail("not_found")
        if (alarm.optString("state") !in listOf("ringing", "snoozed")) return fail("not_ringing")
        cancelPending(id)
        store.event(alarm, if (timedOut) "timed_out" else if (emergency) "emergency_dismissed" else "dismissed")
        resolve(alarm)
        refreshService()
        return success(alarm)
    }

    private fun silenceAfterPersistenceFailure(id: String) {
        // Process-local only: we cannot claim a saved dismissal when storage failed.
        // Suppression prevents the UI's resume/poll path restarting this same sound.
        silencedAlarmIds.add(id)
        safetyError = "emergency_state_not_saved"
        context.stopService(Intent(context, AlarmRingingService::class.java))
        // A different queued alarm can continue if its state remains readable.
        try { refreshService() } catch (_: Exception) { }
    }

    /** Receivers verify occurrence and due time so stale broadcasts cannot reset a budget. */
    fun fire(id: String, occurrenceId: String, expectedAt: Long): Boolean {
        val alarm = store.get(id) ?: return false
        if (!alarm.optBoolean("enabled") || alarm.optString("occurrenceId") != occurrenceId || alarm.optLong("nextAt") != expectedAt) return false
        if (alarm.optString("state") !in listOf("scheduled", "snoozed", "ringing")) return false
        val now = System.currentTimeMillis()
        if (now + 1_000L < expectedAt) return false
        if (alarm.optLong("firedAt") == 0L) alarm.put("firedAt", now)
        val ringingSince = AlarmRules.ringingSinceAfterFire(alarm.optString("state"), alarm.optLong("ringingSince"), now)
        alarm.put("state", "ringing").put("ringingSince", ringingSince).put("nextAt", 0L)
        store.put(alarm)
        store.event(alarm, "fired", now)
        return true
    }

    fun ringing(): JSONObject? = store.alarms().filter { it.optString("state") == "ringing" && it.optString("id") !in silencedAlarmIds }
        .minByOrNull { it.optLong("ringingSince") }

    fun getRingingAlarm(): Map<String, Any?>? = ringing()?.toMap()

    /** A separate native occurrence exercises delivery without changing the user's schedule. */
    fun testAlarm(id: String, delayValue: Any? = null): Map<String, Any?> {
        val delaySeconds = AlarmRules.testDelaySeconds(delayValue) ?: return fail("invalid_test_delay")
        if (AlarmRules.isPreviewId(id)) return fail("invalid_id")
        val alarm = store.get(id) ?: return fail("not_found")
        if (alarm.optString("state") in listOf("ringing", "snoozed")) return fail("alarm_active")
        if (store.alarms().any {
            AlarmRules.isPreviewId(it.optString("id")) && it.optBoolean("enabled") &&
                it.optString("state") in listOf("scheduled", "ringing", "snoozed")
        }) return fail("test_alarm_active")
        // A dedicated occurrence preserves the user's real schedule.
        val testId = "preview:${UUID.randomUUID()}"
        val args = alarm.toMap().toMutableMap()
        args["id"] = testId
        args["enabled"] = true
        args["title"] = "Пробный подъём"
        args["weekdays"] = emptyList<Int>()
        val startedAt = System.currentTimeMillis()
        return scheduleInternal(args, TestMetadata(id, startedAt, startedAt + delaySeconds * 1_000L))
    }

    /** Idempotent preview cleanup. A ringing test uses the same emergency-silence safety path. */
    fun cancelTestAlarm(id: String): Map<String, Any?> {
        if (!AlarmRules.isPreviewId(id)) return fail("invalid_test_id")
        return AlarmSafety.resolveOrSilence(
            operation = {
                val alarm = store.get(id) ?: return@resolveOrSilence mapOf("ok" to true)
                cancelPending(id)
                if (alarm.optString("state") == "ringing") {
                    dismissPersisted(id, emergency = true, timedOut = false)
                }
                store.remove(id)
                silencedAlarmIds.remove(id)
                refreshService()
                mapOf("ok" to true)
            },
            silenceWithoutPersistence = { silenceAfterPersistenceFailure(id) },
            failure = { fail("emergency_state_not_saved", it.message) },
        )
    }

    /** Explicit foreground retry also reconciles audio after resolving an expired saved ring. */
    fun restoreAlarms(): Map<String, Any?> {
        reschedule(skipRinging = true)
        refreshService()
        val failure = recoveryFailure ?: store.recoveryError
        return if (failure == null) mapOf("ok" to true) else fail(failure)
    }

    /** Boot/time changes only schedule AlarmManager work; never start media playback from boot. */
    fun reschedule(clockChanged: Boolean = false, skipRinging: Boolean = false) {
        val now = System.currentTimeMillis()
        var failure: String? = null
        try {
            val alarms = store.alarms().filter { it.optBoolean("enabled") }
            if (alarms.isNotEmpty() && !canSchedule()) {
                failure = "exact_alarm_permission"
            } else alarms.forEach { alarm ->
                try {
                    val plan = AlarmRules.recoveryPlan(
                        enabled = true,
                        state = alarm.optString("state"),
                        nextAt = alarm.optLong("nextAt"),
                        ringingSince = alarm.optLong("ringingSince", now),
                        now = now,
                        clockChanged = clockChanged,
                        preview = AlarmRules.isPreviewId(alarm.optString("id")),
                        oneShot = alarm.optLong("oneShotAt") > 0L,
                        skipRinging = skipRinging,
                    )
                    when (plan.action) {
                        AlarmRules.RecoveryAction.IGNORE -> Unit
                        AlarmRules.RecoveryAction.REARM, AlarmRules.RecoveryAction.NEXT_OCCURRENCE -> {
                            // Never mint another occurrence or reset snoozes during recovery.
                            val next = if (plan.action == AlarmRules.RecoveryAction.NEXT_OCCURRENCE)
                                nextOccurrence(alarm, now) else plan.nextAt
                            alarm.put("nextAt", next)
                            store.put(alarm)
                            arm(alarm)
                        }
                        AlarmRules.RecoveryAction.RESOLVE -> {
                            store.event(alarm, checkNotNull(plan.event), now)
                            resolve(alarm, onScheduleFailure = { failure = "exact_alarm_permission" })
                        }
                    }
                } catch (_: SecurityException) {
                    // Access can change between canSchedule and setAlarmClock.
                    failure = "exact_alarm_permission"
                } catch (_: Exception) {
                    // Keep saved state for a later retry and expose restoration failure.
                    failure = "schedule_failed"
                }
            }
            // TIME_SET may resolve the last playing occurrence while no Activity is open.
            // A preview's old timeout would otherwise see not_ringing and leave audio running.
            // A fresh successful store read is required; read failure leaves existing audio alone.
            AlarmSafety.stopRecoveredPlaybackIfIdle(
                hasRingingAlarm = { ringing() != null },
                stopPlayback = { context.stopService(Intent(context, AlarmRingingService::class.java)) },
            )
        } catch (_: Exception) {
            failure = "schedule_failed"
        }
        recoveryFailure = failure
        try { store.recoveryError = failure }
        catch (_: Exception) { recoveryFailure = "schedule_failed" }
    }

    private fun resolve(alarm: JSONObject, onScheduleFailure: (() -> Unit)? = null) {
        val repeats = alarm.optJSONArray("weekdays")?.length() ?: 0
        if (repeats == 0) {
            alarm.put("enabled", false).put("state", "disabled").put("nextAt", 0L)
        } else {
            alarm.put("occurrenceId", UUID.randomUUID().toString())
                .put("state", "scheduled").put("snoozesUsed", 0).put("snoozedMinutes", 0)
                .put("firedAt", 0L).put("ringingSince", 0L)
                .put("nextAt", nextOccurrence(alarm))
        }
        if (AlarmRules.isPreviewId(alarm.getString("id")) && !alarm.optBoolean("enabled")) {
            store.remove(alarm.getString("id"))
        } else {
            store.put(alarm)
        }
        silencedAlarmIds.remove(alarm.getString("id"))
        if (alarm.optBoolean("enabled") && canSchedule()) {
            try {
                arm(alarm)
            } catch (_: SecurityException) {
                // A concurrent permission revocation must never prevent dismissing today's sound.
                store.event(alarm, "schedule_failed")
                onScheduleFailure?.invoke()
            }
        } else if (alarm.optBoolean("enabled")) {
            onScheduleFailure?.invoke()
        }
    }

    private fun arm(alarm: JSONObject) {
        val id = alarm.getString("id")
        val show = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java)
            .setData(Uri.parse("fivemore://show/${Uri.encode(id)}"))
            .putExtra("alarmId", id).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        manager.setAlarmClock(AlarmManager.AlarmClockInfo(alarm.getLong("nextAt"), show), pending(alarm))
    }

    private fun pending(alarm: JSONObject): PendingIntent = PendingIntent.getBroadcast(context, 0,
        Intent(context, AlarmReceiver::class.java).setAction(ACTION_FIRE)
            .setData(Uri.parse("fivemore://fire/${Uri.encode(alarm.getString("id"))}"))
            .putExtra("alarmId", alarm.getString("id"))
            .putExtra("occurrenceId", alarm.optString("occurrenceId"))
            .putExtra("expectedAt", alarm.optLong("nextAt")),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    private fun cancelPending(id: String) {
        val intent = Intent(context, AlarmReceiver::class.java).setAction(ACTION_FIRE)
            .setData(Uri.parse("fivemore://fire/${Uri.encode(id)}"))
        val pending = PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE)
        if (pending != null) {
            manager.cancel(pending)
            pending.cancel()
        }
    }

    private fun refreshService() {
        if (ringing() == null) {
            context.stopService(Intent(context, AlarmRingingService::class.java))
        } else {
            val intent = Intent(context, AlarmRingingService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
        }
    }

    private fun success(alarm: JSONObject) = mapOf("ok" to true, "nextAt" to alarm.optLong("nextAt"), "snoozesUsed" to alarm.optInt("snoozesUsed"), "alarm" to alarm.toMap())

    companion object {
        const val ACTION_FIRE = "dev.ilyamedve.fivemore.FIRE"
        const val ACTION_SNOOZE = "dev.ilyamedve.fivemore.SNOOZE"
        private val silencedAlarmIds = mutableSetOf<String>()
        private var safetyError: String? = null
        private var recoveryFailure: String? = null

        fun fail(error: String, message: String? = null): Map<String, Any?> = mapOf("ok" to false, "error" to error, "message" to message)

        fun nextOccurrence(alarm: JSONObject, now: Long = System.currentTimeMillis()): Long {
            val days = alarm.optJSONArray("weekdays") ?: JSONArray()
            val weekdays = (0 until days.length()).map { days.getInt(it) }.toSet()
            return AlarmRules.nextOccurrence(alarm.getInt("hour"), alarm.getInt("minute"), weekdays, now)
        }
    }
}
