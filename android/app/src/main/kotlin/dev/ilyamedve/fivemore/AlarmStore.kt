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

    private fun eventRecord(alarm: JSONObject, type: String, at: Long): JSONObject = JSONObject()
            .put("eventId", UUID.randomUUID().toString())
            .put("id", alarm.getString("id"))
            .put("occurrenceId", alarm.optString("occurrenceId"))
            .put("configurationId", alarm.optString("configurationId"))
            .put("type", type)
            .put("at", at)
            .put("snoozesUsed", alarm.optInt("snoozesUsed"))
            .put("snoozedMinutes", alarm.optInt("snoozedMinutes"))
            .put("snoozeMinutes", alarm.optInt("snoozeMinutes", 5))
            .put("nextAt", alarm.optLong("nextAt"))
            .put("enabled", alarm.optBoolean("enabled"))

    fun event(alarm: JSONObject, type: String, at: Long = System.currentTimeMillis()) {
        val all = jsonArray(prefs.getString("events", null))
        all.put(eventRecord(alarm, type, at))
        check(prefs.edit().putString("events", all.toString()).commit())
    }

    /** A stopped one-shot and its pending history are a single durable commit. */
    fun finishOneShot(alarm: JSONObject, type: String) {
        val events = jsonArray(prefs.getString("events", null))
        events.put(eventRecord(alarm, type, System.currentTimeMillis()))
        alarm.put("enabled", false).put("state", "disabled").put("nextAt", 0L)
        val all = alarms().filterNot { it.optString("id") == alarm.optString("id") } + alarm
        check(prefs.edit().putString("events", events.toString()).putString("alarms", JSONArray(all).toString()).commit())
    }

    fun drainEvents(): List<Map<String, Any?>> {
        val all = jsonArray(prefs.getString("events", null))
        return (0 until all.length()).map { all.getJSONObject(it).toMap() }
    }

    /** Acknowledge only after Flutter has durably persisted its copy of these events. */
    fun ackEvents(ids: Set<String>) {
        val all = jsonArray(prefs.getString("events", null))
        val remaining = JSONArray()
        var configs = alarms()
        for (i in 0 until all.length()) {
            val event = all.getJSONObject(i)
            if (event.optString("eventId") !in ids) remaining.put(event)
            else if (event.optString("type") in setOf("dismissed", "emergency_dismissed")) {
                configs = configs.filterNot { alarm ->
                    !AlarmRules.isPreviewId(alarm.optString("id")) &&
                    alarm.optString("id") == event.optString("id") &&
                    alarm.optString("configurationId").isNotEmpty() &&
                    alarm.optString("configurationId") == event.optString("configurationId") &&
                    alarm.optString("occurrenceId") == event.optString("occurrenceId") &&
                    alarm.optString("state") == "disabled" && alarm.optBoolean("deleteAfterDismiss") &&
                    (alarm.optJSONArray("weekdays")?.length() ?: 0) == 0
                }
            }
        }
        check(prefs.edit().putString("events", remaining.toString()).putString("alarms", JSONArray(configs).toString()).commit())
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
