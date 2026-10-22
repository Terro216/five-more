package dev.ilyamedve.fivemore

import java.util.Calendar
import java.util.TimeZone

/** Pure scheduling rules shared by the receiver/service and covered without an Android runtime. */
object AlarmRules {
    data class Snooze(val used: Int, val nextAt: Long)

    /** MethodChannel integers may arrive as Int or Long; never truncate a fractional delay. */
    fun testDelaySeconds(value: Any?): Int? {
        val seconds = when (value) {
            null -> 5L
            is Int -> value.toLong()
            is Long -> value
            else -> return null
        }
        return seconds.takeIf { it in 5L..60L }?.toInt()
    }

    /** A test cancellation must never accept an ordinary alarm identifier. */
    fun isPreviewId(id: String): Boolean = id.startsWith("preview:") && id.length > 8

    fun nextSnooze(now: Long, used: Int, minutes: Int, limit: Int): Snooze? {
        if (used < 0 || minutes !in 1..30 || limit !in 0..10 || used >= limit) return null
        return Snooze(used + 1, now + minutes * 60_000L)
    }

    /** Calendar days, not 24-hour additions, preserve selected wall time across DST. */
    fun nextOccurrence(
        hour: Int,
        minute: Int,
        weekdays: Set<Int>,
        now: Long,
        zone: TimeZone = TimeZone.getDefault(),
    ): Long {
        require(hour in 0..23 && minute in 0..59 && weekdays.all { it in 1..7 })
        val base = Calendar.getInstance(zone).apply { timeInMillis = now }
        for (offset in 0..7) {
            val next = (base.clone() as Calendar).apply {
                add(Calendar.DAY_OF_YEAR, offset)
                set(Calendar.HOUR_OF_DAY, hour)
                set(Calendar.MINUTE, minute)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
            }
            val isoDay = (next.get(Calendar.DAY_OF_WEEK) + 5) % 7 + 1
            if ((weekdays.isEmpty() || isoDay in weekdays) && next.timeInMillis > now) return next.timeInMillis
        }
        error("No next occurrence")
    }
}
