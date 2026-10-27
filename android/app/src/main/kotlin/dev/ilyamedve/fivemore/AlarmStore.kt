package dev.ilyamedve.fivemore

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Durable state is written synchronously before an alarm or notification action is acknowledged. */
class AlarmStore(context: Context) {
    private val storage = context.createDeviceProtectedStorageContext()
    private val prefs = storage.getSharedPreferences("five_more_alarms", Context.MODE_PRIVATE)

    fun alarms(): List<JSONObject> = jsonArray(prefs.getString("alarms", null))
        .let { array ->
            (0 until array.length()).map { index ->
                array.getJSONObject(index).also { alarm ->
                    // Reading a pre-v0.3 occurrence must not silently opt it into harder challenges.
                    // Its next ordinary native write persists this additive default.
                    if (!alarm.has("escalateOnSnooze")) alarm.put("escalateOnSnooze", false)
                    if (!alarm.has("moveSnoozeButton")) alarm.put("moveSnoozeButton", false)
                }
            }
        }

    fun get(id: String): JSONObject? = alarms().firstOrNull { it.optString("id") == id }

    var recoveryError: String?
        get() = prefs.getString("recoveryError", null)
        set(value) {
            check(prefs.edit().putString("recoveryError", value).commit()) { "Cannot persist alarm recovery result" }
        }

    fun put(alarm: JSONObject) {
        val all = alarms().filterNot { it.optString("id") == alarm.getString("id") } + alarm
        check(prefs.edit().putString("alarms", JSONArray(all).toString()).commit()) { "Cannot persist alarm" }
    }

    fun remove(id: String) {
        check(prefs.edit().putString("alarms", JSONArray(alarms().filterNot { it.optString("id") == id }).toString()).commit())
    }

    fun event(alarm: JSONObject, type: String, at: Long = System.currentTimeMillis()) {
        val event = JSONObject()
            .put("eventId", UUID.randomUUID().toString())
            .put("id", alarm.getString("id"))
            .put("occurrenceId", alarm.optString("occurrenceId"))
            .put("type", type)
            .put("at", at)
            .put("snoozesUsed", alarm.optInt("snoozesUsed"))
            .put("snoozeMinutes", alarm.optInt("snoozeMinutes", 5))
            .put("nextAt", alarm.optLong("nextAt"))
            .put("enabled", alarm.optBoolean("enabled"))
        val all = jsonArray(prefs.getString("events", null))
        all.put(event)
        check(prefs.edit().putString("events", all.toString()).commit())
    }

    fun drainEvents(): List<Map<String, Any?>> {
        val all = jsonArray(prefs.getString("events", null))
        return (0 until all.length()).map { all.getJSONObject(it).toMap() }
    }

    /** Acknowledge only after Flutter has durably persisted its copy of these events. */
    fun ackEvents(ids: Set<String>) {
        val all = jsonArray(prefs.getString("events", null))
        val remaining = JSONArray()
        for (i in 0 until all.length()) {
            val event = all.getJSONObject(i)
            if (event.optString("eventId") !in ids) remaining.put(event)
        }
        check(prefs.edit().putString("events", remaining.toString()).commit())
    }

    private fun jsonArray(raw: String?): JSONArray = if (raw == null) JSONArray() else JSONArray(raw)
}

fun JSONObject.toMap(): Map<String, Any?> = keys().asSequence().associateWith { key ->
    when (val value = get(key)) {
        JSONObject.NULL -> null
        is JSONObject -> value.toMap()
        is JSONArray -> (0 until value.length()).map { value.get(it) }
        else -> value
    }
}
