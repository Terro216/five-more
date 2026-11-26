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
    private var recordingLimitMs = 300_000L
    private var completedRecording: Map<String, Any>? = null
    private val recordingHandler = Handler(Looper.getMainLooper())
    private val stopAtLimit = Runnable { try { completedRecording = stopRecording() } catch (_: Exception) {} }
    private fun scheduleRecordingLimit() {
        recordingHandler.removeCallbacks(stopAtLimit)
        recordingHandler.postDelayed(stopAtLimit, (recordingLimitMs - (SystemClock.elapsedRealtime() - startedAt)).coerceAtLeast(1L))
    }
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
                        check(AlarmEngine(activity).ringing() == null) { activity.appText(R.string.dismiss_the_alarm_before_recording_a_message) }
                        check(recorder == null && pendingPermission == null) { activity.appText(R.string.recording_already_started) }
                        if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                            pendingPermission = result
                            activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 601)
                        } else { startRecording(); result.success(null) }
                    }
                    "stopRecording" -> result.success(stopRecording())
                    "extendRecording" -> {
                        check(recorder != null) { activity.appText(R.string.recording_already_finished) }
                        recordingLimitMs += 300_000L; scheduleRecordingLimit(); result.success(null)
                    }
                    "timeZone" -> result.success(java.util.TimeZone.getDefault().id)
                    "readNote" -> {
                        val file = localNote(args["file"])
                        check(file.length() <= 20_000_000L) { activity.appText(R.string.this_recording_is_too_large_to_upload) }
                        result.success(file.readBytes())
                    }
                    "writeNote" -> {
                        val data = args["bytes"] as? ByteArray ?: error(activity.appText(R.string.no_recording))
                        require(data.size <= 20_000_000) { activity.appText(R.string.this_recording_is_too_large) }
                        val file = localNote(args["file"])
                        if (!file.exists()) {
                            val temporary = File(file.parentFile, "${file.name}.part")
                            try { temporary.writeBytes(data); check(temporary.renameTo(file)) { activity.appText(R.string.couldnt_save_the_recording) } }
                            finally { temporary.delete() }
                        }
                        result.success(null)
                    }
                    "playNote" -> { play(Uri.fromFile(localNote(args["file"]))); result.success(null) }
                    "deleteNote" -> { stopPlayer(); val file = localNote(args["file"]); check(!file.exists() || file.delete()) { activity.appText(R.string.couldnt_delete_the_recording) }; result.success(null) }
                    "stopAudio" -> { stopPlayer(); result.success(null) }
                    "previewSound" -> {
                        val sound = args["sound"] as? String ?: "system"
                        play(soundUri(activity, sound)); result.success(null)
                        handler.postDelayed({ stopPlayer() }, 5000)
                    }
                    "pickSound" -> {
                        check(pendingFile == null) { activity.appText(R.string.the_file_picker_is_already_open) }
                        pendingFile = result
                        try {
                            activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply { type = "audio/*"; addCategory(Intent.CATEGORY_OPENABLE) }, 602)
                        } catch (e: Exception) { pendingFile = null; throw e }
                    }
                    "readBackground" -> result.success(AlarmBackgrounds.read(activity, args["file"] as? String ?: ""))
                    "pickBackground" -> {
                        check(pendingFile == null) { activity.appText(R.string.the_file_picker_is_already_open) }
                        pendingFile = result
                        try {
                            activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply { type = "image/*"; addCategory(Intent.CATEGORY_OPENABLE) }, 603)
                        } catch (e: Exception) { pendingFile = null; throw e }
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) { result.error("extras_error", e.message ?: activity.appText(R.string.couldnt_complete_this_action), null) }
        }
    }
    private fun localNote(value: Any?): File {
        val name = value as? String ?: error(activity.appText(R.string.recording_not_found))
        require(Regex("[a-fA-F0-9-]+\\.m4a").matches(name)) { activity.appText(R.string.invalid_recording) }
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
            completedRecording = null; recordingLimitMs = 300_000L; scheduleRecordingLimit()
        } catch (e: Exception) { candidate.release(); file.delete(); throw e }
    }
    private fun stopRecording(): Map<String, Any>? {
        val active = recorder ?: return completedRecording.also { completedRecording = null }
        recordingHandler.removeCallbacks(stopAtLimit)
        recorder = null
        val file = recordingFile ?: error(activity.appText(R.string.recording_not_found))
        try { active.stop() } catch (e: Exception) { file.delete(); throw IllegalStateException(activity.appText(R.string.the_recording_was_too_short_try_again), e) }
        finally { active.release() }
        return mapOf("file" to file.name, "seconds" to ((SystemClock.elapsedRealtime() - startedAt) / 1000).coerceAtLeast(0))
    }
    private fun play(uri: Uri) {
        check(AlarmEngine(activity).ringing() == null) { activity.appText(R.string.dismiss_the_alarm_before_playing_the_recording) }
        stopPlayer()
        val next = MediaPlayer()
        try {
            next.setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).build())
            next.setDataSource(activity, uri); next.prepare(); next.start()
            next.setOnCompletionListener { stopPlayer() }
            player = next
        } catch (e: Exception) { next.release(); throw IllegalStateException(activity.appText(R.string.couldnt_play_the_file), e) }
    }
    private fun stopPlayer() { handler.removeCallbacksAndMessages(null); player?.release(); player = null }
    fun permissionResult(code: Int, grants: IntArray): Boolean {
        if (code != 601) return false
        val result = pendingPermission ?: return true
        pendingPermission = null
        try {
            if (grants.firstOrNull() != PackageManager.PERMISSION_GRANTED) error(activity.appText(R.string.allow_microphone_access_in_app_settings_to_record))
            check(AlarmEngine(activity).ringing() == null) { activity.appText(R.string.dismiss_the_alarm_first) }
            startRecording(); result.success(null)
        } catch (e: Exception) { result.error("microphone", e.message, null) }
        return true
    }
    fun fileResult(code: Int, resultCode: Int, data: Intent?): Boolean {
        if (code != 602 && code != 603) return false
        val result = pendingFile ?: return true
        pendingFile = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) { result.success(null); return true }
        if (code == 603) {
            Thread {
                try {
                    val name = AlarmBackgrounds.importImage(activity, data.data!!)
                    activity.runOnUiThread { result.success(name) }
                } catch (e: Exception) {
                    activity.runOnUiThread { result.error("background_file", e.message ?: activity.appText(R.string.couldnt_open_the_photo), null) }
                }
            }.start()
            return true
        }
        val file = File(soundDir, "${UUID.randomUUID()}.audio")
        Thread {
        try {
            val uri = data.data!!
            var label = activity.appText(R.string.my_sound)
            activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) label = cursor.getString(0).take(80)
            }
            activity.contentResolver.openInputStream(uri)!!.use { input ->
                file.outputStream().use { output ->
                    val buffer = ByteArray(8192); var total = 0
                    while (true) { val count = input.read(buffer); if (count < 0) break; total += count; require(total <= 40 * 1024 * 1024) { activity.appText(R.string.choose_an_audio_file_of_40_mb_or) }; output.write(buffer, 0, count) }
                }
            }
            val probe = MediaPlayer()
            try { probe.setDataSource(file.absolutePath); probe.prepare(); require(probe.duration > 0) { activity.appText(R.string.this_file_has_no_audio) } } finally { probe.release() }
            activity.runOnUiThread { result.success(mapOf("sound" to "file:${file.name}", "label" to label)) }
        } catch (e: Exception) { file.delete(); activity.runOnUiThread { result.error("audio_file", e.message ?: activity.appText(R.string.this_audio_format_isnt_supported), null) } }
        }.start()
        return true
    }
    fun dispose() {
        recordingHandler.removeCallbacksAndMessages(null)
        recorder?.let { try { it.stop() } catch (_: Exception) {} ; it.release() }; recorder = null
        stopPlayer()
        pendingPermission?.error("closed", activity.appText(R.string.recording_window_closed), null); pendingPermission = null
        pendingFile?.error("closed", activity.appText(R.string.file_picker_closed), null); pendingFile = null
    }
    companion object {
        fun soundUri(context: Context, sound: String): Uri {
            if (sound.startsWith("file:")) {
                val name = sound.removePrefix("file:")
                require(Regex("[a-fA-F0-9-]+\\.audio").matches(name)) { context.appText(R.string.invalid_audio_file) }
                val file = File(context.createDeviceProtectedStorageContext().filesDir, "alarm_sounds/$name")
                require(file.isFile) { context.appText(R.string.this_alarm_sound_is_unavailable_choose_it_again) }
                return Uri.fromFile(file)
            }
            val resource = when (sound) { "arcade" -> R.raw.arcade; "sunrise" -> R.raw.sunrise; "pulse" -> R.raw.pulse; "classic" -> R.raw.alarm_tone; else -> 0 }
            return if (resource == 0) android.media.RingtoneManager.getDefaultUri(android.media.RingtoneManager.TYPE_ALARM)
                else Uri.parse("android.resource://${context.packageName}/$resource")
        }
    }
}

object BedtimeReminder {
    internal const val CHANNEL = "bedtime_v1"
    private fun prefs(context: Context) = context.createDeviceProtectedStorageContext().getSharedPreferences("bedtime", Context.MODE_PRIVATE)
    private fun pending(context: Context) = PendingIntent.getBroadcast(context, 711, Intent(context, BedtimeReceiver::class.java).setAction("dev.ilyamedve.fivemore.BEDTIME"), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    fun configure(context: Context, enabled: Boolean, hour: Int, minute: Int) {
        require(hour in 0..23 && minute in 0..59)
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, context.appText(R.string.bedtime), NotificationManager.IMPORTANCE_DEFAULT))
        if (enabled) {
            check(manager.areNotificationsEnabled() && manager.getNotificationChannel(CHANNEL).importance != NotificationManager.IMPORTANCE_NONE) { context.appText(R.string.allow_app_notifications_in_your_phone_settings) }
            check(AlarmEngine(context).canSchedule()) { context.appText(R.string.allow_exact_alarms_in_your_phone_settings) }
            schedule(context, hour, minute)
        } else context.getSystemService(AlarmManager::class.java).cancel(pending(context))
        check(prefs(context).edit().putBoolean("enabled", enabled).putInt("hour", hour).putInt("minute", minute).remove("error").commit()) { context.appText(R.string.couldnt_save_the_reminder) }
    }
    private fun schedule(context: Context, hour: Int, minute: Int) {
        val now = System.currentTimeMillis()
        val next = Calendar.getInstance().apply { set(Calendar.HOUR_OF_DAY, hour); set(Calendar.MINUTE, minute); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0); if (timeInMillis <= now) add(Calendar.DAY_OF_YEAR, 1) }
        context.getSystemService(AlarmManager::class.java).setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next.timeInMillis, pending(context))
    }
    fun state(context: Context): Map<String, Any?> {
        val p = prefs(context)
        val manager = context.getSystemService(NotificationManager::class.java)
        val allowed = manager.areNotificationsEnabled() && manager.getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE && AlarmEngine(context).canSchedule()
        return mapOf("enabled" to p.getBoolean("enabled", false), "error" to if (p.getBoolean("enabled", false) && !allowed) context.appText(R.string.check_bedtime_reminder_permissions_in_your_phone_settings) else if (p.contains("error")) context.appText(R.string.couldnt_restore_the_bedtime_reminder_turn_it_on) else null)
    }
    fun restore(context: Context) {
        val p = prefs(context)
        if (p.getBoolean("enabled", false)) {
            try { schedule(context, p.getInt("hour", 23), p.getInt("minute", 0)); p.edit().remove("error").commit() }
            catch (_: Exception) { p.edit().putString("error", "restore_failed").commit() }
        }
    }
    fun deliver(context: Context) {
        if (!prefs(context).getBoolean("enabled", false)) return
        val open = PendingIntent.getActivity(context, 712, Intent(context, MainActivity::class.java).putExtra("bedtime", true).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(context, CHANNEL).setSmallIcon(R.drawable.ic_alarm_notification)
            .setContentTitle(context.appText(R.string.time_to_wind_down))
            .setContentText(context.appText(R.string.listen_to_your_morning_message_before_bed))
            .setContentIntent(open).setAutoCancel(true).setVisibility(Notification.VISIBILITY_PRIVATE).build()
        try { context.getSystemService(NotificationManager::class.java).notify(713, notification) } catch (_: SecurityException) {}
        restore(context)
    }
}
class BedtimeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) { BedtimeReminder.deliver(context) }
}
