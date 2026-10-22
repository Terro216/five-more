# Android alarm engine

Android 8 / API 26 is the minimum. Flutter draws the screens and verifies wake-up tasks; Kotlin owns alarm scheduling, sound, snooze budgets and durable occurrence state. The engine uses only Android SDK APIs and a bundled generated WAV sound.

## Delivery and recovery

- `AlarmManager.setAlarmClock()` schedules one exact occurrence. A native broadcast receiver starts a `mediaPlayback` foreground service. A high-importance full-screen notification opens Flutter's wake-up screen. The notification's wake-up action does **not** silence the alarm.
- App UI/process closure is not the alarm timer. Each snooze is another system alarm and carries the original occurrence ID and persisted snooze count. Updating or disabling an active occurrence through normal settings is rejected.
- `escalateOnSnooze` is an optional opt-in saved with the base challenge difficulty. Existing configurations without it retain `false`. Snooze, process recovery, reboot and preview copies preserve the setting; native code continues to own the actual `snoozesUsed` count. Flutter uses that count to raise the challenge by one level per snooze, capped at hard, without changing the saved base difficulty. The next ordinary occurrence starts with a fresh count.
- Configurations and the bounded 512-event journal live in device-protected SharedPreferences; critical writes use synchronous `commit()`. Audio falls back from the system alarm ringtone to the bundled WAV if the system ringtone is unavailable, including before first unlock after reboot.
- Boot, package replacement and wall-clock/timezone changes restore the schedules. Boot receivers **only reschedule system alarms** and do not start a media playback service directly. A recent missed occurrence is retried; one more than 15 minutes late is marked missed. Snoozed occurrences retain their budget after reboot.
- Weekday recurrence uses local calendar days, not fixed 24-hour intervals. Nonexistent spring DST times normalize forward using Android's Calendar; repeated autumn times use Calendar's selected occurrence once. A timezone change recalculates scheduled alarms in local time, while an existing snooze keeps its absolute deadline.
- Unanswered ringing has a 15-minute safety timeout and records `timed_out`. It then schedules the next recurring date or disables a one-shot alarm. An explicit in-app emergency exit records `emergency_dismissed`.
- If emergency/timeout persistence fails, an independent path silences the current sound and prevents restarting it within this process. It reports `emergency_state_not_saved`, without claiming that dismissal or the next schedule was durably saved. Other queued alarms may continue if their stored state is readable. The user must check storage and the schedule before relying on a later occurrence.
- Multiple due alarms retain separate budgets. The service presents the oldest ringing occurrence; resolving it reveals the next. This does not mix multiple simultaneous audio streams.

## Permissions and limits

`USE_EXACT_ALARM` is declared for Android 13+ because this application's core purpose is an alarm clock; Android 12 uses the special `SCHEDULE_EXACT_ALARM` grant. Runtime notification and full-screen-intent access are surfaced to the user. Permission setup opens one step at a time and status is rechecked on resume. Disabled notification channels are treated as unavailable notification access.

The service respects the user's alarm stream volume and Do Not Disturb configuration; it does not silently modify global settings. Its own ten-second volume ramp and delayed vibration are independent of global volume. Full-screen presentation depends on OS permission and state; an unlocked phone may show a heads-up notification instead. Before first unlock after a reboot, native sound/notification can work while the Flutter task screen may require unlocking.

The device checklist reads the current alarm stream volume and its maximum, plus whether standard Android battery optimization applies to this app. These are diagnostics, not a guarantee of delivery: battery optimization being enabled does not by itself mean an exact alarm will fail, and the flag cannot describe every manufacturer's background restriction. Explicit checklist actions open only the selected permission/setting. Battery settings use the general optimization list, with an app-details fallback; the app does not request a privileged battery-exemption permission or change volume automatically.

Force-stop, a powered-off phone, system/OEM restrictions, unavailable permissions, a zero alarm stream volume, hardware faults and user removal of the app can prevent waking. No emulator/build result establishes reliability on a person's handset. Keep an independent alarm during the initial device trial.

## Flutter method channel

Channel: `five_more/alarm`.

| Method | Input | Output |
| --- | --- | --- |
| `schedule` | `id,title,hour,minute,weekdays,enabled,snoozeMinutes,maxSnoozes,challengeKind,difficulty`, optional boolean `escalateOnSnooze` (default false) | `{ok,nextAt,snoozesUsed,alarm}` or `{ok:false,error,message}` |
| `cancel` | `id` | Disable inactive schedule; active alarms return `alarm_active` |
| `snooze` | Ringing `id` | Native budget checked; returns `snooze_limit` without stopping sound when exhausted |
| `dismiss` | Ringing `id`, optional `emergency` | Resolve after Flutter task verification, or emergency exit |
| `status` | — | Permission flags, `batteryOptimized`, `alarmVolume`, `alarmMaxVolume` and complete native `alarms` snapshots, including disabled configurations |
| `requestPermissions` | Optional `target`: `notifications`, `exactAlarms`, `fullScreenIntent`, `battery`, `alarmVolume` | Opens only that setting/request; omitted target opens the next missing permission step. Returns current status; recheck on resume. Unavailable settings return `ok:false,error:settings_unavailable` |
| `getRingingAlarm` | — | Flattened configuration with `occurrenceId,firedAt,ringingSince,snoozesUsed,state`, or null |
| `drainEvents` | — | Pending event list; repeated reads return the same IDs until acknowledged |
| `ackEvents` | `eventIds` | Removes only those IDs after Flutter durably saved them |
| `testAlarm` | Existing `id`, optional integer `delaySeconds` (5–60, default 5) | Creates a separate one-shot `preview:<UUID>` and returns its `alarm.id` and `nextAt`; preserves the real schedule. Rejects an existing pending, ringing or snoozed preview with `test_alarm_active` |
| `cancelTestAlarm` | Returned preview `id` only | Cancels a pending/snoozed test or emergency-dismisses a ringing test, then removes its state. Idempotent for a missing preview. Ordinary IDs return `invalid_test_id` without changes |

ISO weekdays are Monday=1 through Sunday=7. Empty weekdays means a one-shot next occurrence. Native scheduling always recomputes the next occurrence from hour/minute/weekdays; any stale `nextAt` in a Flutter snapshot is ignored. Only the internal preview helper supplies an explicit short deadline. Preview deadlines remain absolute across timezone changes, and resolved test configurations are removed. `nextAt=0` means no future occurrence. Delivery to Flutter is at-least-once within the bounded journal; Flutter deduplicates by event ID and acknowledges after persistence. Event types are `fired`, `snoozed`, `dismissed`, `emergency_dismissed`, `timed_out`, `missed`, and `schedule_failed`. Each event has a stable UUID, alarm ID, occurrence ID, epoch-millisecond timestamp and snooze count. Flutter merges native enabled/nextAt state without deleting local drafts and excludes `preview:` configurations from its regular alarm list.

New schedule requests accept challenge kinds `math`, `memory`, `stroop`, `sequence` and `mixed`, and difficulty `easy`, `medium` or `hard`. Unknown values or a non-boolean `escalateOnSnooze` return `invalid_challenge` before changing a schedule; strings and numbers never opt the user in. Missing kind/difficulty retain the historical `math`/`medium` defaults. Preview copies of legacy configurations use the same safe fallback for unknown old kinds as Flutter.

## Required physical-device checks

These remain manual release gates, not claims of completed testing:

1. Grant permissions, schedule a real alarm, lock the phone, close the UI and verify sound, vibration and wake-up task.
2. Repeat offline and in Doze; verify notification snooze actions consume the same budget as Flutter buttons.
3. Exhaust the budget; process recreation must not restore extra snoozes. Notification wake-up must keep sound playing until task completion.
4. Reboot before and during a snooze; test before first unlock and afterwards.
5. Disable notification/full-screen/exact access separately and verify the app exposes the missing access.
6. Test two due alarms, one-shot auto-disable, weekday recurrence, timezone changes and a DST transition.
7. Verify emergency exit, timeout and sound fallback. Test alarm volume zero and Bluetooth routing explicitly.
8. Start a delayed test, lock the screen, cancel before delivery, and cancel once already ringing. Repeat after reopening the app; test cancellation must leave ordinary alarms unchanged. Verify the selected checklist row opens its matching Android panel and status refreshes on return.
9. Enable challenge escalation on an easy alarm, snooze using both the notification and Flutter, and reopen the process between snoozes. Verify medium then hard, never beyond hard; the next recurring morning must start at easy. Existing alarms with escalation off must keep their selected difficulty.

## Primary API references

- [AlarmManager and exact alarms](https://developer.android.com/develop/background-work/services/alarms)
- [AlarmManager.setAlarmClock](https://developer.android.com/reference/android/app/AlarmManager#setAlarmClock(android.app.AlarmManager.AlarmClockInfo,%20android.app.PendingIntent))
- [Android 15 foreground service boot restrictions](https://developer.android.com/about/versions/15/changes/foreground-service-types)
- [Foreground service background-start exemptions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)
- [Direct boot](https://developer.android.com/privacy-and-security/direct-boot)
- [Battery optimization status](https://developer.android.com/reference/android/os/PowerManager#isIgnoringBatteryOptimizations(java.lang.String))
- [Android settings panels](https://developer.android.com/reference/android/provider/Settings)
