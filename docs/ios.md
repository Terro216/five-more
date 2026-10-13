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
- The system configuration, occurrence identifier, snooze budget and bounded
  event queue live in native UserDefaults, independent of the Dart process.
  `LiveActivityIntent` runs in the app process, so no App Group is required.
  `drainEvents` peeks without deleting; `ackEvents` removes explicit event IDs
  only after Flutter has persisted them, making repeated delivery deduplicable.
  Finished snooze instances and preview configurations are removed. Expired
  action guards are cleaned during status reads; missing transient instances
  get a one-day grace period for delayed system intents before being pruned.
- A test alarm gets a separate `preview:<UUID>` logical identifier and system
  UUID. It fires in ten seconds and never edits the original configuration.
- The system default sound is used. There is no server or network requirement.

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
6. Verify restart, daylight-saving changes, timezone changes, overlapping
   alarms, and locked-device App Intent behavior on the target iOS release.

Simulator compilation is useful but does not establish physical-device alarm
reliability. Signing/distribution and device testing are separate release work.

References: [AlarmKit scheduling](https://developer.apple.com/documentation/alarmkit/scheduling-an-alarm-with-alarmkit),
[AlarmManager](https://developer.apple.com/documentation/alarmkit/alarmmanager),
[WWDC25 AlarmKit session](https://developer.apple.com/videos/play/wwdc2025/230/).
