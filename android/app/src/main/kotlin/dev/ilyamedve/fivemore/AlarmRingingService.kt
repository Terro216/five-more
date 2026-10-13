package dev.ilyamedve.fivemore

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import org.json.JSONObject

/** Owns sound and buttons independently of the Flutter engine and activity lifecycle. */
class AlarmRingingService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private var player: MediaPlayer? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var currentOccurrence: String? = null
    private var currentId: String? = null
    private val vibration: Vibrator by lazy {
        if (Build.VERSION.SDK_INT >= 31) getSystemService(VibratorManager::class.java).defaultVibrator
        else @Suppress("DEPRECATION") (getSystemService(VIBRATOR_SERVICE) as Vibrator)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val channel = NotificationChannel(CHANNEL_ID, "Будильник", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Срабатывание будильника и кнопки пробуждения"
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            // Sound is controlled by the service; channel defaults must not play it twice.
            setSound(null, null)
            enableVibration(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        wakeLock = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "five_more:ringing")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val alarm = AlarmEngine(this).ringing()
        if (alarm == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        val notification = notification(alarm)
        if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        else startForeground(NOTIFICATION_ID, notification)
        if (currentOccurrence != alarm.optString("occurrenceId")) {
            currentOccurrence = alarm.optString("occurrenceId")
            currentId = alarm.getString("id")
            handler.removeCallbacksAndMessages(null)
            stopSound()
            wakeLock?.let {
                if (it.isHeld) it.release()
                it.acquire(AlarmEngine.MAX_RING_MS + 60_000L)
            }
            startSound()
            val remaining = (AlarmEngine.MAX_RING_MS - (System.currentTimeMillis() - alarm.optLong("ringingSince"))).coerceAtLeast(1L)
            handler.postDelayed({
                val id = currentId ?: return@postDelayed
                AlarmEngine(this).dismiss(id, timedOut = true)
            }, remaining)
        }
        return START_STICKY
    }

    private fun notification(alarm: JSONObject): Notification {
        val id = alarm.getString("id")
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java)
                .setData(Uri.parse("fivemore://ring/${Uri.encode(id)}"))
                .putExtra("alarmId", id)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_alarm_notification)
            .setContentTitle(alarm.optString("title").ifBlank { "Ещё пять" })
            .setContentText("Пора вставать · открой задание, чтобы отключить")
            .setCategory(Notification.CATEGORY_ALARM)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            .setContentIntent(open)
            .setFullScreenIntent(open, true)
            .addAction(Notification.Action.Builder(null, "Проснуться", open).build())
        if (alarm.optInt("snoozesUsed") < alarm.optInt("maxSnoozes", 3)) {
            val snooze = PendingIntent.getBroadcast(this, 0,
                Intent(this, AlarmReceiver::class.java).setAction(AlarmEngine.ACTION_SNOOZE)
                    .setData(Uri.parse("fivemore://snooze/${Uri.encode(id)}"))
                    .putExtra("alarmId", id)
                    .putExtra("occurrenceId", alarm.optString("occurrenceId")),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            builder.addAction(Notification.Action.Builder(null, "Ещё ${alarm.optInt("snoozeMinutes", 5)} мин", snooze).build())
        }
        return builder.build()
    }

    private fun startSound() {
        val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
        // Device ringtone can be inaccessible before unlock, so a bundled sound is mandatory.
        val uris = listOfNotNull(
            RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM),
            Uri.parse("android.resource://$packageName/${R.raw.alarm_tone}"),
        )
        for (uri in uris) {
            val candidate = MediaPlayer()
            try {
                candidate.setAudioAttributes(attributes)
                candidate.setDataSource(this, uri)
                candidate.isLooping = true
                candidate.setVolume(0.08f, 0.08f)
                candidate.prepare()
                candidate.start()
                player = candidate
                break
            } catch (_: Exception) {
                candidate.release()
            }
        }
        // Ten-second gentle ramp; never modify the user's global alarm volume setting.
        for (step in 1..20) handler.postDelayed({
            val volume = (0.08f + 0.92f * step / 20f).coerceAtMost(1f)
            player?.setVolume(volume, volume)
        }, step * 500L)
        handler.postDelayed({
            vibration.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 500, 650, 500, 1500), 0), attributes)
        }, 5_000L)
    }

    private fun stopSound() {
        player?.let {
            try { it.stop() } catch (_: IllegalStateException) { }
            it.release()
        }
        player = null
        vibration.cancel()
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        stopSound()
        wakeLock?.let { if (it.isHeld) it.release() }
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    companion object {
        const val CHANNEL_ID = "five_more_alarm_v1"
        const val NOTIFICATION_ID = 504
    }
}
