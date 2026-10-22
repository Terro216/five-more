# iOS alarm engine

The iOS app uses Apple's native AlarmKit (iOS 26+) through the
`five_more/alarm` Flutter method channel. A toolchain without AlarmKit reports
`supported: false`; practice challenges remain available. Build with Xcode 26
or newer and an iOS 26 SDK. Add `FiveMoreAlarmBridge.swift` to the Runner source
build phase and provide `NSAlarmKitUsageDescription` in Info.plist.

## Scheduling and persistence

- Original alarms use relative wall-clock schedules with a weekly recurrence
  or `.never` for one-off alarms. AlarmKit owns delivery while Flutter is closed.
- Snoozes are separate fixed alarms with random system UUIDs. Stopping the
  current occurrence does not overwrite the original recurring configuration.
  A failed snooze creation leaves the current alarm ringing. If stopping the
  current alarm fails, the new snooze is cancelled.
- The optional boolean `escalateOnSnooze` is saved with the base challenge
  difficulty and preserved in snooze and preview configurations. Older saved
  alarms without it return `false`; reads do not rewrite the store. Flutter
  computes the current challenge from the native `snoozesUsed` count, one level
  per snooze up to hard. Native code keeps the base difficulty unchanged and
  starts the next ordinary occurrence with a fresh count. New schedule requests
  reject strings/numbers in this boolean and accept only `math`, `memory`,
  `stroop`, `sequence`, `mixed` and the `easy`/`medium`/`hard` difficulty levels.
- The system configuration, occurrence identifier, snooze budget and bounded
  event queue live in native UserDefaults, independent of the Dart process.
  `LiveActivityIntent` runs in the app process, so no App Group is required.
  `drainEvents` peeks without deleting; `ackEvents` removes explicit event IDs
  only after Flutter has persisted them, making repeated delivery deduplicable.
  Finished snooze instances and preview configurations are removed. Expired
  action guards are cleaned during status reads; missing transient instances
  get a one-day grace period for delayed system intents before being pruned.
- A test alarm gets a separate `preview:<UUID>` logical identifier and system
  UUID. `testAlarm` accepts an optional integer `delaySeconds` from 5 through 60
  (default 5), and returns the preview `alarm.id` and exact `nextAt`. It never
  edits the original configuration. An existing registered test, including a
  snoozed test, rejects another start with `test_alarm_active`.
- `cancelTestAlarm` accepts only the returned nonempty `preview:` identifier.
  It cancels a pending test or stops a ringing test with an emergency-dismissal
  event, then removes its configuration and occurrences. An already removed
  preview succeeds without changes; an ordinary ID returns `invalid_test_id`.
- The system default sound is used. There is no server or network requirement.

`requestPermissions` accepts optional `target: notifications` or `exactAlarms`;
both represent AlarmKit authorization on iOS. When access has been denied, the
action opens this app's Settings page. Other explicit targets return
`ok:false,error:settings_unavailable`; no Android battery or volume diagnostics
are fabricated on iOS. Returning from Settings triggers a fresh status check;
opening it is not proof of authorization.

## Intentional platform differences

**iOS does not enforce solving a challenge before stopping the system alarm.**
The AlarmKit Stop button remains available and is recorded as
`emergency_dismissed`. The bridge returns `challengeEnforced: false` so the UI
can state this honestly. The custom secondary `Задание` action opens the app;
its intent never calls `stop`. The app stops the alarm after challenge success
or a confirmed emergency exit. Device testing must verify whether each iOS
release continues sounding while the custom action opens the app.

Snooze is offered inside the app. There is no system countdown presentation or
Live Activity extension, because AlarmKit requires a widget extension when a
countdown is configured. This implementation uses alert-only presentations.

AlarmKit does not execute arbitrary app code when an alarm starts sounding.
The event history records alert observations and intent interactions. The
native `firedAt` field is the first observed time, not proof of the precise
sound start time. It is not a complete delivery audit when the app never runs.

## Required device checks before relying on the alarm

1. Grant and revoke AlarmKit authorization; confirm UI status follows it.
2. Schedule one-off and weekday alarms, then lock the phone and terminate the
   app. Verify audible delivery, including Focus and silent mode.
3. Use `Задание`, complete a challenge, and exercise emergency/system Stop.
4. Snooze to the configured limit; kill and reopen the app between snoozes.
   Verify the next ordinary weekly occurrence is still present.
5. Test an existing alarm and verify its original schedule is unchanged.
   Also cancel a delayed test before it sounds, then cancel one while ringing;
   reopening the app must not create an additional test or restore a cancelled one.
6. Verify restart, daylight-saving changes, timezone changes, overlapping
   alarms, and locked-device App Intent behavior on the target iOS release.
7. Enable escalation on an easy alarm and reopen the app between snoozes.
   Verify medium then hard, with the next recurring morning starting at easy.
   Alarms created before this option or with it disabled keep their selected
   difficulty. System Stop remains available regardless of the option.

Simulator compilation is useful but does not establish physical-device alarm
reliability. Signing/distribution and device testing are separate release work.

References: [AlarmKit scheduling](https://developer.apple.com/documentation/alarmkit/scheduling-an-alarm-with-alarmkit),
[AlarmManager](https://developer.apple.com/documentation/alarmkit/alarmmanager),
[app Settings URL](https://developer.apple.com/documentation/uikit/uiapplication/opensettingsurlstring),
[WWDC25 AlarmKit session](https://developer.apple.com/videos/play/wwdc2025/230/).
