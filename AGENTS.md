# Five More / Ещё пять

Flutter mobile app, offline by default. Android and iOS native alarm engines
must remain usable when Flutter is not running. A browser build is a UI and
challenge preview, never an actual background alarm.

- Keep alarm creation short; put advanced choices behind explicit controls.
- Preserve native occurrence IDs and snooze counts across process death.
- Never silence a real Android alarm just because a challenge screen opens.
- iOS AlarmKit has a system stop control: do not claim mandatory captchas on iOS.
- Emergency dismissal is always available and recorded separately.
- Scheduling failures must reach the user; never show an unscheduled alarm as active.
- No tracking SDKs, accounts, or voice uploads. Statistics and recordings stay local.
  Online mirror phrases require explicit opt-in; never fetch during an alarm.
- Device-check success is an explicit user report, never inferred from a native event.
- Test occurrences have preview-only IDs; cancellation must not change real schedules.
- Snooze escalation uses the native occurrence counter; keep the saved base level unchanged.
- Existing alarms never opt into escalation implicitly. A wrong answer returns
  exactly one challenge stage, bounded at the first stage.
- Hard and extreme challenges must require materially greater effort; retain
  accessible controls and the emergency exit at every difficulty.
- Keep SDK version pinned in `.flutter-version` and CI. Commit `pubspec.lock`.
- Run `dart format --output=none --set-exit-if-changed lib test`,
  `flutter analyze`, `flutter test`, and build Android APK after native changes.
- For iOS changes, run the macOS build CI. Device alarm checks are separate from
  compilation; document any checks that have not been performed.
- Do not commit build output, signing keys, provisioning profiles, or SDK caches.
- GitHub repository is public. Keep infrastructure details, personal paths and
  recovery procedures out of source, history, releases and build artifacts.
  Publication to stores requires a separate request.
