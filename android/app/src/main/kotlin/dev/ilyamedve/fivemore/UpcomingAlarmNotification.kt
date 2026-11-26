package dev.ilyamedve.fivemore

import android.app.Notification
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build

/** SystemUI draws the countdown. No service, periodic alarm, wake lock or network. */
object UpcomingAlarmNotification {
    internal const val CHANNEL = "upcoming_alarm"
    private const val ID = 4102
    private fun prefs(context: Context) = context.createDeviceProtectedStorageContext()
        .getSharedPreferences("upcoming_alarm_notification", Context.MODE_PRIVATE)

    // An optional notification failure must never affect real scheduling or ringing.
    fun refresh(context: Context) { runCatching { update(context) } }

    private fun update(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        val now = System.currentTimeMillis()
        val store = AlarmStore(context)
        if ((Build.VERSION.SDK_INT >= 31 && !context.getSystemService(AlarmManager::class.java).canScheduleExactAlarms()) ||
            store.recoveryError != null) {
            manager.cancel(ID)
            return
        }
        val next = UpcomingAlarmRules.next(store.alarms().map {
            UpcomingAlarmRules.Candidate(it.optString("id"), it.optString("occurrenceId"),
                it.optString("state"), it.optBoolean("enabled"), it.optLong("nextAt"), it.optString("title"))
        }, now)
        val prefs = prefs(context)
        if (next == null || !manager.areNotificationsEnabled() ||
            prefs.getStringSet("dismissed", emptySet())!!.contains(next.key)) {
            manager.cancel(ID)
            return
        }
        val channel = NotificationChannel(CHANNEL, context.appText(R.string.upcoming_alarm), NotificationManager.IMPORTANCE_DEFAULT)
            .apply { description = context.appText(R.string.upcoming_alarm_description)
                setSound(null, null); enableVibration(false) }
        manager.createNotificationChannel(channel)
        if (manager.getNotificationChannel(CHANNEL)?.importance == NotificationManager.IMPORTANCE_NONE) return
        val open = PendingIntent.getActivity(context, 4102,
            Intent(context, MainActivity::class.java).setData(Uri.parse("fivemore://upcoming"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val hide = PendingIntent.getBroadcast(context, 4102,
            Intent(context, UpcomingAlarmDismissReceiver::class.java)
                .setData(Uri.parse("fivemore://hide-countdown/${Uri.encode(next.key)}"))
                .putExtra("key", next.key),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val time = context.upcomingClockLabel(next.nextAt)
        val text = next.title.ifBlank { context.appText(R.string.time_until_alarm_swipe_to_hide) }
        val previous = manager.activeNotifications.firstOrNull { it.id == ID }?.notification
        if (previous != null && previous.`when` == next.nextAt &&
            previous.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() == context.appText(R.string.upcoming_alarm_time, time) &&
            previous.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() == text) return
        val notification = Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_alarm_notification)
            .setContentTitle(context.appText(R.string.upcoming_alarm_time, time))
            .setContentText(text)
            .setWhen(next.nextAt).setUsesChronometer(true).setChronometerCountDown(true)
            .setOnlyAlertOnce(true).setOngoing(false).setAutoCancel(false)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setContentIntent(open).setDeleteIntent(hide)
            .setTimeoutAfter(next.nextAt - now)
            .build()
        manager.notify(ID, notification)
    }

    fun dismiss(context: Context, key: String) {
        if (key.length > 400) return
        val prefs = prefs(context)
        val hidden = prefs.getStringSet("dismissed", emptySet())!!.toMutableSet()
        hidden.add(key)
        check(prefs.edit().putStringSet("dismissed", hidden.takeLastKeys(100)).commit())
    }

    private fun Set<String>.takeLastKeys(limit: Int): Set<String> = toList().takeLast(limit).toSet()
}

class UpcomingAlarmDismissReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val key = intent.getStringExtra("key") ?: return
        runCatching { UpcomingAlarmNotification.dismiss(context, key) }
    }
}
