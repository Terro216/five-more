# Five More / Ещё пять

Flutter mobile app, offline by default. Android and iOS native alarm engines
must remain usable when Flutter is not running. A browser build is a UI and
challenge preview, never an actual background alarm.

- Keep alarm creation short; put advanced choices behind explicit controls.
- Preserve native occurrence IDs and snooze counts across process death.
- Never silence a real Android alarm just because a challenge screen opens.
- Real Android wake-ups never expire by timer or reboot; previews remain bounded.
  Optional power-menu protection requires explicit consent and Android activation.
  Intercept only recognized, focused SystemUI power windows while a real alarm
  rings; never inspect app content or close settings, calls, or unknown windows.
- iOS AlarmKit has a system stop control: do not claim mandatory captchas on iOS.
- Emergency dismissal is always available and recorded separately.
- Scheduling failures must reach the user; never show an unscheduled alarm as active.
- No tracking SDKs. Offline alarms never depend on an account or the sync service.
  Statistics sync requires explicit opt-in. Audio sync additionally requires a
  server-side account allowlist and separate consent; default-deny for all others.
  The server can decrypt statistics and audio; never describe this as end-to-end
  encryption. Keep tokens in platform secure storage and recovery keys out of logs.
  Online mirror phrases require explicit opt-in; suspend network work during alarms.
- History lives in SQLite. Preserve legacy data until migration succeeds; native
  events are acknowledged only after durable local persistence. Paginate archives
  independently of graph aggregates. Snooze limits use spent minutes, never count.
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
