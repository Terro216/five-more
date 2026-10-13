package dev.ilyamedve.fivemore

import android.app.AlarmManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** The native engine, not Flutter, owns every active occurrence and its snooze budget. */
class AlarmEngine(private val context: Context) {
    private val store = AlarmStore(context)
    private val manager = context.getSystemService(AlarmManager::class.java)

    fun status(): Map<String, Any?> = mapOf(
        "platform" to "android",
        "supported" to true,
        "exactAlarms" to canSchedule(),
        "notifications" to notificationsEnabled(),
        "fullScreenIntent" to fullScreenAvailable(),
        "scheduledCount" to store.alarms().count { it.optBoolean("enabled") },
        "alarms" to store.alarms().map { it.toMap() },
        "error" to safetyError,
    )

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

    fun schedule(arguments: Map<*, *>, previewAt: Long? = null): Map<String, Any?> {
        val id = arguments["id"] as? String ?: return fail("invalid_id")
        if (id.isBlank() || id.length > 128) return fail("invalid_id")
        val old = store.get(id)
        if (old != null && old.optString("state") in listOf("ringing", "snoozed")) return fail("alarm_active")
        val hour = (arguments["hour"] as? Number)?.toInt() ?: return fail("invalid_hour")
        val minute = (arguments["minute"] as? Number)?.toInt() ?: return fail("invalid_minute")
        val snoozeMinutes = (arguments["snoozeMinutes"] as? Number)?.toInt() ?: 5
        val maxSnoozes = (arguments["maxSnoozes"] as? Number)?.toInt() ?: 3
        val weekdays = (arguments["weekdays"] as? List<*>)?.mapNotNull { (it as? Number)?.toInt() } ?: emptyList()
        if (hour !in 0..23 || minute !in 0..59 || snoozeMinutes !in 1..30 || maxSnoozes !in 0..10 || weekdays.any { it !in 1..7 }) return fail("invalid_schedule")
        val enabled = arguments["enabled"] as? Boolean ?: true
        if (enabled && !canSchedule()) return fail("exact_alarm_permission")
        val alarm = JSONObject()
            .put("id", id).put("title", (arguments["title"] as? String ?: "Ещё пять").take(160))
            .put("hour", hour).put("minute", minute).put("weekdays", JSONArray(weekdays.distinct()))
            .put("enabled", enabled).put("snoozeMinutes", snoozeMinutes).put("maxSnoozes", maxSnoozes)
            .put("challengeKind", arguments["challengeKind"] as? String ?: "math")
            .put("difficulty", arguments["difficulty"] ?: "medium")
            .put("snoozesUsed", 0).put("occurrenceId", UUID.randomUUID().toString())
            .put("state", if (enabled) "scheduled" else "disabled")
        val nextAt = if (enabled) {
            if (previewAt != null && id.startsWith("preview:") && previewAt > System.currentTimeMillis()) previewAt else nextOccurrence(alarm)
        } else 0L
        alarm.put("nextAt", nextAt)
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

    fun snooze(id: String): Map<String, Any?> {
        val alarm = store.get(id) ?: return fail("not_found")
        if (alarm.optString("state") != "ringing") return fail("not_ringing")
        val snooze = AlarmRules.nextSnooze(System.currentTimeMillis(), alarm.optInt("snoozesUsed"), alarm.optInt("snoozeMinutes", 5), alarm.optInt("maxSnoozes", 3))
            ?: return fail("snooze_limit")
        if (!canSchedule()) return fail("exact_alarm_permission")
        val previous = JSONObject(alarm.toString())
        alarm.put("snoozesUsed", snooze.used)
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
        alarm.put("state", "ringing").put("ringingSince", now).put("nextAt", 0L)
        store.put(alarm)
        store.event(alarm, "fired", now)
        return true
    }

    fun ringing(): JSONObject? = store.alarms().filter { it.optString("state") == "ringing" && it.optString("id") !in silencedAlarmIds }
        .minByOrNull { it.optLong("ringingSince") }

    fun getRingingAlarm(): Map<String, Any?>? = ringing()?.toMap()

    /** A real five-second native alarm exercises the background/lock-screen delivery path. */
    fun testAlarm(id: String): Map<String, Any?> {
        val alarm = store.get(id) ?: return fail("not_found")
        if (alarm.optString("state") in listOf("ringing", "snoozed")) return fail("alarm_active")
        // A dedicated occurrence preserves the user's real schedule.
        val testId = "preview:$id"
        val args = alarm.toMap().toMutableMap()
        args["id"] = testId
        args["enabled"] = true
        args["weekdays"] = emptyList<Int>()
        return schedule(args, previewAt = System.currentTimeMillis() + 5_000L)
    }

    /** Boot/time changes only schedule AlarmManager work; never start media playback from boot. */
    fun reschedule(clockChanged: Boolean = false, skipRinging: Boolean = false) {
        if (!canSchedule()) return
        val now = System.currentTimeMillis()
        store.alarms().forEach { alarm ->
            if (!alarm.optBoolean("enabled")) return@forEach
            try {
                when (alarm.optString("state")) {
                    "ringing" -> {
                        if (skipRinging) return@forEach
                        // Preserve the occurrence and budget after process death/reboot.
                        if (now - alarm.optLong("ringingSince", now) < MAX_RING_MS) {
                            alarm.put("nextAt", now + 2_000L)
                            store.put(alarm)
                            arm(alarm)
                        } else {
                            store.event(alarm, "timed_out")
                            resolve(alarm)
                        }
                    }
                    "snoozed" -> {
                        if (alarm.optLong("nextAt") <= now) {
                            if (now - alarm.optLong("nextAt") > MAX_RING_MS) {
                                store.event(alarm, "missed")
                                resolve(alarm)
                                return@forEach
                            }
                            alarm.put("nextAt", now + 2_000L)
                        }
                        store.put(alarm)
                        arm(alarm)
                    }
                    "scheduled" -> {
                        if (clockChanged) {
                            alarm.put("nextAt", nextOccurrence(alarm))
                        } else if (alarm.optLong("nextAt") <= now) {
                            if (now - alarm.optLong("nextAt") <= MAX_RING_MS) {
                                alarm.put("nextAt", now + 2_000L)
                            } else {
                                store.event(alarm, "missed")
                                resolve(alarm)
                                return@forEach
                            }
                        }
                        store.put(alarm)
                        arm(alarm)
                    }
                }
            } catch (_: SecurityException) {
                // Access can be revoked between canSchedule and setAlarmClock. UI reports it on resume.
            }
        }
    }

    private fun resolve(alarm: JSONObject) {
        val repeats = alarm.optJSONArray("weekdays")?.length() ?: 0
        if (repeats == 0) {
            alarm.put("enabled", false).put("state", "disabled").put("nextAt", 0L)
        } else {
            alarm.put("occurrenceId", UUID.randomUUID().toString())
                .put("state", "scheduled").put("snoozesUsed", 0)
                .put("firedAt", 0L).put("ringingSince", 0L)
                .put("nextAt", nextOccurrence(alarm))
        }
        store.put(alarm)
        silencedAlarmIds.remove(alarm.getString("id"))
        if (alarm.optBoolean("enabled") && canSchedule()) {
            try {
                arm(alarm)
            } catch (_: SecurityException) {
                // A concurrent permission revocation must never prevent dismissing today's sound.
                store.event(alarm, "schedule_failed")
            }
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
        const val MAX_RING_MS = 15 * 60_000L
        private val silencedAlarmIds = mutableSetOf<String>()
        private var safetyError: String? = null

        fun fail(error: String, message: String? = null): Map<String, Any?> = mapOf("ok" to false, "error" to error, "message" to message)

        fun nextOccurrence(alarm: JSONObject, now: Long = System.currentTimeMillis()): Long {
            val days = alarm.optJSONArray("weekdays") ?: JSONArray()
            val weekdays = (0 until days.length()).map { days.getInt(it) }.toSet()
            return AlarmRules.nextOccurrence(alarm.getInt("hour"), alarm.getInt("minute"), weekdays, now)
        }
    }
}
