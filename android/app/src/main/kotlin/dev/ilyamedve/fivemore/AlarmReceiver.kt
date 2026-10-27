package dev.ilyamedve.fivemore

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val engine = AlarmEngine(context)
        if (intent.action != AlarmEngine.ACTION_FIRE && intent.action != AlarmEngine.ACTION_SNOOZE) BedtimeReminder.restore(context)
        when (intent.action) {
            AlarmEngine.ACTION_FIRE -> {
                val id = intent.getStringExtra("alarmId") ?: return
                val occurrence = intent.getStringExtra("occurrenceId") ?: return
                if (engine.fire(id, occurrence, intent.getLongExtra("expectedAt", -1L))) {
                    val service = Intent(context, AlarmRingingService::class.java)
                    if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(service) else context.startService(service)
                }
            }
            AlarmEngine.ACTION_SNOOZE -> {
                val id = intent.getStringExtra("alarmId") ?: return
                val occurrence = intent.getStringExtra("occurrenceId") ?: return
                if (AlarmStore(context).get(id)?.optString("occurrenceId") != occurrence) return
                engine.snooze(id)
            }
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED" -> engine.reschedule()
            Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_TIMEZONE_CHANGED -> engine.reschedule(clockChanged = true)
        }
    }
}
