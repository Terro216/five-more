package dev.ilyamedve.fivemore

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.SystemClock
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Calendar
import java.util.UUID

/** Local recordings and reminders never share the alarm service's player. */
class ExtrasBridge(private val activity: MainActivity, private val channel: MethodChannel) {
    private var recorder: MediaRecorder? = null
    private var recordingFile: File? = null
    private var startedAt = 0L
    private var player: MediaPlayer? = null
    private var pendingPermission: MethodChannel.Result? = null
    private var pendingFile: MethodChannel.Result? = null
    private val handler = Handler(Looper.getMainLooper())
    private val noteDir get() = File(activity.filesDir, "morning_notes").apply { mkdirs() }
    private val soundDir get() = File(activity.createDeviceProtectedStorageContext().filesDir, "alarm_sounds").apply { mkdirs() }

    fun bedtimeOpened() { channel.invokeMethod("bedtimeOpened", null) }

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                when (call.method) {
                    "version" -> {
                        val info = activity.packageManager.getPackageInfo(activity.packageName, 0)
                        result.success("${info.versionName} (${if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong()})")
                    }
                    "listNotes" -> {
                        val notes = noteDir.listFiles()?.mapNotNull { file ->
                            if (!Regex("[a-fA-F0-9-]+\\.m4a").matches(file.name)) return@mapNotNull null
                            val metadata = android.media.MediaMetadataRetriever()
                            try {
                                metadata.setDataSource(file.absolutePath)
                                val ms = metadata.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0
                                if (ms < 300) null else mapOf("file" to file.name, "at" to file.lastModified(), "seconds" to (ms / 1000))
                            } catch (_: Exception) { null } finally { metadata.release() }
                        } ?: emptyList()
                        result.success(notes)
                    }
                    "bedtimeState" -> result.success(BedtimeReminder.state(activity))
                    "takeBedtimeOpen" -> {
                        result.success(activity.intent?.getBooleanExtra("bedtime", false) == true)
                        activity.intent?.removeExtra("bedtime")
                    }
                    "bedtime" -> {
                        BedtimeReminder.configure(activity, args["enabled"] == true, (args["hour"] as Number).toInt(), (args["minute"] as Number).toInt())
                        result.success(null)
                    }
                    "startRecording" -> {
                        check(AlarmEngine(activity).ringing() == null) { "Сначала заверши подъём, затем запиши послание." }
                        check(recorder == null && pendingPermission == null) { "Запись уже начата" }
                        if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                            pendingPermission = result
                            activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 601)
                        } else { startRecording(); result.success(null) }
                    }
                    "stopRecording" -> result.success(stopRecording())
                    "playNote" -> { play(Uri.fromFile(localNote(args["file"]))); result.success(null) }
                    "deleteNote" -> { stopPlayer(); check(localNote(args["file"]).delete()) { "Не удалось удалить запись" }; result.success(null) }
                    "stopAudio" -> { stopPlayer(); result.success(null) }
                    "previewSound" -> {
                        val sound = args["sound"] as? String ?: "system"
                        play(soundUri(activity, sound)); result.success(null)
                        handler.postDelayed({ stopPlayer() }, 5000)
                    }
                    "pickSound" -> {
                        check(pendingFile == null) { "Выбор файла уже открыт" }
                        pendingFile = result
                        try {
                            activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply { type = "audio/*"; addCategory(Intent.CATEGORY_OPENABLE) }, 602)
                        } catch (e: Exception) { pendingFile = null; throw e }
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) { result.error("extras_error", e.message ?: "Не удалось выполнить действие", null) }
        }
    }
    private fun localNote(value: Any?): File {
        val name = value as? String ?: error("Запись не найдена")
        require(Regex("[a-fA-F0-9-]+\\.m4a").matches(name)) { "Неверная запись" }
        return File(noteDir, name)
    }
    @Suppress("DEPRECATION")
    private fun startRecording() {
        stopPlayer()
        val file = File(noteDir, "${UUID.randomUUID()}.m4a")
        val candidate = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(activity) else MediaRecorder()
        try {
            candidate.setAudioSource(MediaRecorder.AudioSource.MIC)
            candidate.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            candidate.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            candidate.setAudioSamplingRate(22050)
            candidate.setAudioEncodingBitRate(64000)
            candidate.setOutputFile(file.absolutePath)
            candidate.prepare(); candidate.start()
            recorder = candidate; recordingFile = file; startedAt = SystemClock.elapsedRealtime()
        } catch (e: Exception) { candidate.release(); file.delete(); throw e }
    }
    private fun stopRecording(): Map<String, Any>? {
        val active = recorder ?: return null
        recorder = null
        val file = recordingFile ?: error("Запись не найдена")
        try { active.stop() } catch (e: Exception) { file.delete(); throw IllegalStateException("Запись слишком короткая. Попробуй ещё раз.", e) }
        finally { active.release() }
        return mapOf("file" to file.name, "seconds" to ((SystemClock.elapsedRealtime() - startedAt) / 1000).coerceAtLeast(0))
    }
    private fun play(uri: Uri) {
        check(AlarmEngine(activity).ringing() == null) { "Прослушай запись после отключения будильника." }
        stopPlayer()
        val next = MediaPlayer()
        try {
            next.setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).build())
            next.setDataSource(activity, uri); next.prepare(); next.start()
            next.setOnCompletionListener { stopPlayer() }
            player = next
        } catch (e: Exception) { next.release(); throw IllegalStateException("Не удалось воспроизвести файл", e) }
    }
    private fun stopPlayer() { handler.removeCallbacksAndMessages(null); player?.release(); player = null }
    fun permissionResult(code: Int, grants: IntArray): Boolean {
        if (code != 601) return false
        val result = pendingPermission ?: return true
        pendingPermission = null
        try {
            if (grants.firstOrNull() != PackageManager.PERMISSION_GRANTED) error("Разреши микрофон в настройках приложения, чтобы записать послание.")
            check(AlarmEngine(activity).ringing() == null) { "Сначала заверши подъём." }
            startRecording(); result.success(null)
        } catch (e: Exception) { result.error("microphone", e.message, null) }
        return true
    }
    fun fileResult(code: Int, resultCode: Int, data: Intent?): Boolean {
        if (code != 602) return false
        val result = pendingFile ?: return true
        pendingFile = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) { result.success(null); return true }
        val file = File(soundDir, "${UUID.randomUUID()}.audio")
        Thread {
        try {
            val uri = data.data!!
            var label = "Моя мелодия"
            activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) label = cursor.getString(0).take(80)
            }
            activity.contentResolver.openInputStream(uri)!!.use { input ->
                file.outputStream().use { output ->
                    val buffer = ByteArray(8192); var total = 0
                    while (true) { val count = input.read(buffer); if (count < 0) break; total += count; require(total <= 40 * 1024 * 1024) { "Выбери аудиофайл до 40 МБ." }; output.write(buffer, 0, count) }
                }
            }
            val probe = MediaPlayer()
            try { probe.setDataSource(file.absolutePath); probe.prepare(); require(probe.duration > 0) { "Файл не содержит звука" } } finally { probe.release() }
            activity.runOnUiThread { result.success(mapOf("sound" to "file:${file.name}", "label" to label)) }
        } catch (e: Exception) { file.delete(); activity.runOnUiThread { result.error("audio_file", e.message ?: "Формат аудио не поддерживается", null) } }
        }.start()
        return true
    }
    fun dispose() {
        recorder?.let { try { it.stop() } catch (_: Exception) {} ; it.release() }; recorder = null
        stopPlayer()
        pendingPermission?.error("closed", "Окно записи закрыто", null); pendingPermission = null
        pendingFile?.error("closed", "Выбор файла закрыт", null); pendingFile = null
    }
    companion object {
        fun soundUri(context: Context, sound: String): Uri {
            if (sound.startsWith("file:")) {
                val name = sound.removePrefix("file:")
                require(Regex("[a-fA-F0-9-]+\\.audio").matches(name)) { "Неверный аудиофайл" }
                val file = File(context.createDeviceProtectedStorageContext().filesDir, "alarm_sounds/$name")
                require(file.isFile) { "Мелодия недоступна. Выбери её снова." }
                return Uri.fromFile(file)
            }
            val resource = when (sound) { "arcade" -> R.raw.arcade; "sunrise" -> R.raw.sunrise; "pulse" -> R.raw.pulse; "classic" -> R.raw.alarm_tone; else -> 0 }
            return if (resource == 0) android.media.RingtoneManager.getDefaultUri(android.media.RingtoneManager.TYPE_ALARM)
                else Uri.parse("android.resource://${context.packageName}/$resource")
        }
    }
}

object BedtimeReminder {
    private const val channel = "bedtime_v1"
    private fun prefs(context: Context) = context.createDeviceProtectedStorageContext().getSharedPreferences("bedtime", Context.MODE_PRIVATE)
    private fun pending(context: Context) = PendingIntent.getBroadcast(context, 711, Intent(context, BedtimeReceiver::class.java).setAction("dev.ilyamedve.fivemore.BEDTIME"), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    fun configure(context: Context, enabled: Boolean, hour: Int, minute: Int) {
        require(hour in 0..23 && minute in 0..59)
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(channel, "Пора спать", NotificationManager.IMPORTANCE_DEFAULT))
        if (enabled) {
            check(manager.areNotificationsEnabled() && manager.getNotificationChannel(channel).importance != NotificationManager.IMPORTANCE_NONE) { "Разреши уведомления приложения в настройках телефона." }
            check(AlarmEngine(context).canSchedule()) { "Разреши точные будильники в настройках телефона." }
            schedule(context, hour, minute)
        } else context.getSystemService(AlarmManager::class.java).cancel(pending(context))
        check(prefs(context).edit().putBoolean("enabled", enabled).putInt("hour", hour).putInt("minute", minute).remove("error").commit()) { "Не удалось сохранить напоминание" }
    }
    private fun schedule(context: Context, hour: Int, minute: Int) {
        val now = System.currentTimeMillis()
        val next = Calendar.getInstance().apply { set(Calendar.HOUR_OF_DAY, hour); set(Calendar.MINUTE, minute); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0); if (timeInMillis <= now) add(Calendar.DAY_OF_YEAR, 1) }
        context.getSystemService(AlarmManager::class.java).setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next.timeInMillis, pending(context))
    }
    fun state(context: Context): Map<String, Any?> {
        val p = prefs(context)
        val manager = context.getSystemService(NotificationManager::class.java)
        val allowed = manager.areNotificationsEnabled() && manager.getNotificationChannel(channel)?.importance != NotificationManager.IMPORTANCE_NONE && AlarmEngine(context).canSchedule()
        return mapOf("enabled" to p.getBoolean("enabled", false), "error" to if (p.getBoolean("enabled", false) && !allowed) "Проверь разрешения вечернего напоминания в настройках телефона." else p.getString("error", null))
    }
    fun restore(context: Context) {
        val p = prefs(context)
        if (p.getBoolean("enabled", false)) {
            try { schedule(context, p.getInt("hour", 23), p.getInt("minute", 0)); p.edit().remove("error").commit() }
            catch (_: Exception) { p.edit().putString("error", "Не удалось восстановить вечернее напоминание. Включи его ещё раз.").commit() }
        }
    }
    fun deliver(context: Context) {
        if (!prefs(context).getBoolean("enabled", false)) return
        val open = PendingIntent.getActivity(context, 712, Intent(context, MainActivity::class.java).putExtra("bedtime", true).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(context, channel).setSmallIcon(R.drawable.ic_alarm_notification)
            .setContentTitle("Пора готовиться ко сну")
            .setContentText("Послушай своё утреннее послание — завтра будет легче вставать.")
            .setContentIntent(open).setAutoCancel(true).setVisibility(Notification.VISIBILITY_PRIVATE).build()
        try { context.getSystemService(NotificationManager::class.java).notify(713, notification) } catch (_: SecurityException) {}
        restore(context)
    }
}
class BedtimeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) { BedtimeReminder.deliver(context) }
}
