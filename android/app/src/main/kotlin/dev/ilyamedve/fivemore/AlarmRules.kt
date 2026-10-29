package dev.ilyamedve.fivemore

import java.util.Calendar
import java.util.TimeZone

/** Pure scheduling rules shared by the receiver/service and covered without an Android runtime. */
object AlarmRules {
    data class Snooze(val used: Int, val nextAt: Long, val totalMinutes: Int = 0)
    data class ChallengeOptions(
        val kind: String,
        val difficulty: String,
        val escalateOnSnooze: Boolean,
        val moveSnoozeButton: Boolean,
    )
    enum class RecoveryAction { IGNORE, REARM, NEXT_OCCURRENCE, RESOLVE }
    data class RecoveryPlan(val action: RecoveryAction, val nextAt: Long = 0L, val event: String? = null)

    /** Replaying an interrupted ring must not restart its fifteen-minute safety limit. */
    fun ringingSinceAfterFire(previousState: String, previousSince: Long, now: Long): Long =
        if (previousState == "ringing" && previousSince > 0L) previousSince else now

    /** Decisions only: the engine applies them without replacing the occurrence or snooze budget. */
    fun recoveryPlan(
        enabled: Boolean,
        state: String,
        nextAt: Long,
        ringingSince: Long,
        now: Long,
        maximumRingMs: Long,
        clockChanged: Boolean = false,
        preview: Boolean = false,
        skipRinging: Boolean = false,
    ): RecoveryPlan {
        if (!enabled) return RecoveryPlan(RecoveryAction.IGNORE)
        if (state == "ringing") {
            if (now - ringingSince >= maximumRingMs) return RecoveryPlan(RecoveryAction.RESOLVE, event = "timed_out")
            if (skipRinging) return RecoveryPlan(RecoveryAction.IGNORE)
            return RecoveryPlan(RecoveryAction.REARM, now + 2_000L)
        }
        if (state !in setOf("scheduled", "snoozed")) return RecoveryPlan(RecoveryAction.IGNORE)
        if (state == "scheduled" && clockChanged && !preview) return RecoveryPlan(RecoveryAction.NEXT_OCCURRENCE)
        if (nextAt > now) return RecoveryPlan(RecoveryAction.REARM, nextAt)
        return if (now - nextAt <= maximumRingMs) RecoveryPlan(RecoveryAction.REARM, now + 2_000L)
            else RecoveryPlan(RecoveryAction.RESOLVE, event = "missed")
    }

    /** New requests are strict; preview copies retain the safe defaults of legacy saved data. */
    fun challengeOptions(arguments: Map<*, *>, fromStoredConfiguration: Boolean = false): ChallengeOptions? {
        val kind = if (arguments.containsKey("challengeKind")) arguments["challengeKind"] else "math"
        val difficulty = if (arguments.containsKey("difficulty")) arguments["difficulty"] else "medium"
        val escalation = if (arguments.containsKey("escalateOnSnooze")) arguments["escalateOnSnooze"] else false
        val movingSnooze = if (arguments.containsKey("moveSnoozeButton")) arguments["moveSnoozeButton"] else false
        val validKind = kind is String && kind in setOf("math", "memory", "stroop", "sequence", "mirror", "captcha", "qr", "shake", "maze", "flags", "mixed")
        val validDifficulty = difficulty is String && difficulty in setOf("easy", "medium", "hard", "extreme")
        if (fromStoredConfiguration) return ChallengeOptions(
            if (validKind) kind as String else "math",
            if (validDifficulty) difficulty as String else "medium",
            escalation as? Boolean ?: false,
            movingSnooze as? Boolean ?: false,
        )
        if (!validKind || !validDifficulty || escalation !is Boolean || movingSnooze !is Boolean) return null
        return ChallengeOptions(kind as String, difficulty as String, escalation, movingSnooze)
    }

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

    fun nextBudgetSnooze(now: Long, used: Int, spentMinutes: Int, minutes: Int, budget: Int): Snooze? {
        if (used < 0 || spentMinutes < 0 || budget !in 0..300 || minutes !in 1..30 || minutes > budget - spentMinutes) return null
        return Snooze(used + 1, now + minutes * 60_000L, spentMinutes + minutes)
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
