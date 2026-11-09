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
import android.media.AudioManager
import android.os.SystemClock
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
    private var currentGeneration = -1
    private var vibrating = false
    private var soundStarted = 0L
    private var previousQuiet = false
    private var previousCall = false
    private var returnStarted: Long? = null
    private var returnFrom = 0f
    private var lastLevel = 0f
    private val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
    private fun callActive(): Boolean = getSystemService(AudioManager::class.java).mode in setOf(
        AudioManager.MODE_RINGTONE, AudioManager.MODE_IN_CALL, AudioManager.MODE_IN_COMMUNICATION, AudioManager.MODE_CALL_SCREENING)

    // One mixer owns the final level. Audio focus loss alone never suppresses an alarm.
    private val mixAudio = object : Runnable {
        override fun run() {
            val id = currentId ?: return
            val alarm = AlarmStore(this@AlarmRingingService).get(id) ?: return
            if (alarm.optString("state") != "ringing" || alarm.optString("occurrenceId") != currentOccurrence || alarm.optInt("snoozesUsed") != currentGeneration) return
            val now = SystemClock.elapsedRealtime()
            val call = callActive()
            val remaining = AlarmEngine(this@AlarmRingingService).quietRemaining(alarm)
            val quiet = remaining > 0L
            if ((previousCall && !call) || (previousQuiet && !quiet)) {
                returnStarted = now
                returnFrom = lastLevel
            }
            val target = AlarmAudioRules.level(now - soundStarted, alarm.optInt("volumeRampSeconds", 10), remaining, null, call)
            val returnProgress = returnStarted?.let { ((now - it) / AlarmAudioRules.RETURN_MS.toFloat()).coerceIn(0f, 1f) } ?: 1f
            val level = if (call) 0f else minOf(target, returnFrom + (target - returnFrom) * returnProgress)
            try { player?.setVolume(level, level) } catch (_: IllegalStateException) { }
            val shouldVibrate = !call && alarm.optBoolean("vibration", true) && now - soundStarted >= 5_000L
            if (shouldVibrate != vibrating) {
                if (shouldVibrate) vibration.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 500, 650, 500, 1500), 0), attributes)
                else vibration.cancel()
                vibrating = shouldVibrate
            }
            lastLevel = level
            previousCall = call
            previousQuiet = quiet
            handler.postDelayed(this, 100L)
        }
    }
    private val renewWakeLock = object : Runnable {
        override fun run() {
            if (currentOccurrence == null) return
            // Bounded acquisitions renew while this foreground alarm owns playback.
            // Process death releases the lock; onDestroy removes this callback.
            wakeLock?.acquire(10 * 60_000L)
            handler.postDelayed(this, 5 * 60_000L)
        }
    }
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
        wakeLock = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "five_more:ringing").apply {
            setReferenceCounted(false)
        }
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
        if (currentOccurrence != alarm.optString("occurrenceId") || currentGeneration != alarm.optInt("snoozesUsed")) {
            currentOccurrence = alarm.optString("occurrenceId")
            currentId = alarm.getString("id")
            currentGeneration = alarm.optInt("snoozesUsed")
            handler.removeCallbacksAndMessages(null)
            stopSound()
            wakeLock?.let { if (it.isHeld) it.release() }
            renewWakeLock.run()
            startSound(alarm)
            AlarmRules.automaticStopDelay(alarm.getString("id"), alarm.optLong("ringingSince"), System.currentTimeMillis())?.let { remaining ->
                handler.postDelayed({
                    val id = currentId ?: return@postDelayed
                    AlarmEngine(this).dismiss(id, timedOut = true)
                }, remaining)
            }
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
            .setContentTitle(alarm.optString("title").ifBlank { "Будильник на %02d:%02d".format(alarm.optInt("hour"), alarm.optInt("minute")) })
            .setContentText(if (alarm.optString("dismissalMode", "challenge") == "normal") "Будильник звонит" else "Открой задание, чтобы отключить")
            .setCategory(Notification.CATEGORY_ALARM)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            .setContentIntent(open)
            .setFullScreenIntent(open, true)
        if (alarm.optString("dismissalMode", "challenge") == "normal") {
            val stop = PendingIntent.getBroadcast(this, 0,
                Intent(this, AlarmReceiver::class.java).setAction(AlarmEngine.ACTION_DISMISS)
                    .setData(Uri.parse("fivemore://dismiss/${Uri.encode(id)}"))
                    .putExtra("alarmId", id).putExtra("occurrenceId", alarm.optString("occurrenceId")),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            builder.addAction(Notification.Action.Builder(null, "Выключить", stop).build())
        } else builder.addAction(Notification.Action.Builder(null, "Проснуться", open).build())
        if (!alarm.optBoolean("moveSnoozeButton") && alarm.optInt("snoozedMinutes", alarm.optInt("snoozesUsed") * alarm.optInt("snoozeMinutes", 5)) < alarm.optInt("snoozeBudgetMinutes", alarm.optInt("maxSnoozes", 3) * alarm.optInt("snoozeMinutes", 5))) {
            val snooze = PendingIntent.getBroadcast(this, 0,
                Intent(this, AlarmReceiver::class.java).setAction(AlarmEngine.ACTION_SNOOZE)
                    .setData(Uri.parse("fivemore://snooze/${Uri.encode(id)}"))
                    .putExtra("alarmId", id)
                    .putExtra("occurrenceId", alarm.optString("occurrenceId")),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val remaining = alarm.optInt("snoozeBudgetMinutes", alarm.optInt("maxSnoozes", 3) * alarm.optInt("snoozeMinutes", 5)) - alarm.optInt("snoozedMinutes", alarm.optInt("snoozesUsed") * alarm.optInt("snoozeMinutes", 5))
            builder.addAction(Notification.Action.Builder(null, "Ещё ${minOf(alarm.optInt("snoozeMinutes", 5), remaining)} мин", snooze).build())
        }
        return builder.build()
    }

    private fun startSound(alarm: JSONObject) {
        val now = SystemClock.elapsedRealtime()
        // Service/Flutter restarts never restart the ramp. Across a boot, return
        // full sound conservatively; wall-clock changes cannot extend it.
        val currentBoot = AlarmEngine(this).bootCount()
        soundStarted = if (currentBoot >= 0 && alarm.optInt("ringBoot", -1) == currentBoot)
            alarm.optLong("ringStartedElapsed", now - 60_000L) else now - 60_000L
        previousCall = callActive()
        previousQuiet = AlarmEngine(this).quietRemaining(alarm) > 0L
        returnStarted = null
        lastLevel = 0f
        // Device ringtone can be inaccessible before unlock, so a bundled sound is mandatory.
        val selected = try { ExtrasBridge.soundUri(this, alarm.optString("sound", "system")) } catch (_: Exception) { null }
        val uris = listOfNotNull(
            selected,
            RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM),
            Uri.parse("android.resource://$packageName/${R.raw.alarm_tone}"),
        )
        for (uri in uris) {
            val candidate = MediaPlayer()
            try {
                candidate.setAudioAttributes(attributes)
                candidate.setDataSource(this, uri)
                candidate.isLooping = true
                val initialVolume = AlarmAudioRules.level(now - soundStarted, alarm.optInt("volumeRampSeconds", 10),
                    AlarmEngine(this).quietRemaining(alarm), null, callActive())
                candidate.setVolume(initialVolume, initialVolume)
                candidate.prepare()
                candidate.start()
                player = candidate
                break
            } catch (_: Exception) {
                candidate.release()
            }
        }
        mixAudio.run()
    }

    private fun stopSound() {
        player?.let {
            try { it.stop() } catch (_: IllegalStateException) { }
            it.release()
        }
        player = null
        vibration.cancel()
        vibrating = false
    }

    override fun onDestroy() {
        currentOccurrence = null
        currentId = null
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
