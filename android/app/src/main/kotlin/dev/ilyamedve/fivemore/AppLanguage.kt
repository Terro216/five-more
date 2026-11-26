package dev.ilyamedve.fivemore

import android.app.NotificationManager
import android.app.LocaleManager
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.os.LocaleList
import android.text.format.DateFormat
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/** The legacy preference must also be readable before the first unlock. */
object AppLanguage {
    private fun prefs(context: Context) = context.createDeviceProtectedStorageContext()
        .getSharedPreferences("app_language", Context.MODE_PRIVATE)

    fun get(context: Context): String {
        val legacy = prefs(context)
        if (Build.VERSION.SDK_INT < 33) return legacy.getString("language", "") ?: ""
        val manager = context.getSystemService(LocaleManager::class.java)
        if (legacy.contains("language")) {
            val previous = legacy.getString("language", "")
            if (manager.applicationLocales.isEmpty && !previous.isNullOrEmpty()) {
                manager.applicationLocales = LocaleList.forLanguageTags(previous)
            }
            legacy.edit().remove("language").apply()
        }
        return manager.applicationLocales.toLanguageTags().substringBefore('-').substringBefore(',')
    }

    fun set(context: Context, language: String) {
        require(language in setOf("", "en", "ru"))
        if (Build.VERSION.SDK_INT >= 33) {
            context.getSystemService(LocaleManager::class.java).applicationLocales = LocaleList.forLanguageTags(language)
        } else {
            check(prefs(context).edit().putString("language", language).commit())
        }
        refreshNotifications(context)
    }

    fun refreshNotifications(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        fun rename(id: String, label: Int, description: Int? = null) {
            val channel = manager.getNotificationChannel(id) ?: return
            channel.name = context.appText(label)
            if (description != null) channel.description = context.appText(description)
            manager.createNotificationChannel(channel)
        }
        runCatching {
            rename(AlarmRingingService.CHANNEL_ID, R.string.alarm, R.string.ringing_alarms_and_wake_up_controls)
            rename(UpcomingAlarmNotification.CHANNEL, R.string.upcoming_alarm, R.string.upcoming_alarm_description)
            rename(BedtimeReminder.CHANNEL, R.string.bedtime)
        }
        UpcomingAlarmNotification.refresh(context)
    }

    fun localized(context: Context): Context {
        if (Build.VERSION.SDK_INT >= 33) return context
        val language = get(context)
        if (language.isEmpty()) return context
        val configuration = Configuration(context.resources.configuration)
        configuration.setLocale(Locale.forLanguageTag(language))
        return context.createConfigurationContext(configuration)
    }
}

fun Context.appText(id: Int, vararg values: Any): String =
    AppLanguage.localized(this).getString(id, *values)

fun Context.alarmClockLabel(hour: Int, minute: Int): String {
    val clock = Calendar.getInstance().apply {
        set(Calendar.HOUR_OF_DAY, hour)
        set(Calendar.MINUTE, minute)
    }
    return DateFormat.getTimeFormat(AppLanguage.localized(this)).format(clock.time)
}

fun Context.upcomingClockLabel(at: Long): String {
    val context = AppLanguage.localized(this)
    val locale = context.resources.configuration.locales[0]
    val skeleton = if (DateFormat.is24HourFormat(context)) "EEEHm" else "EEEhm"
    return SimpleDateFormat(DateFormat.getBestDateTimePattern(locale, skeleton), locale).format(Date(at))
}
