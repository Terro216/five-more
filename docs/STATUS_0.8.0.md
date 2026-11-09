# Five More 0.8.0 — implementation and verification

The accepted scope is [IMPLEMENTATION_0.8.0.md](IMPLEMENTATION_0.8.0.md).
Installation candidate: **0.8.1+12**, including the 0.8.0 scope and a DST boundary correction. Existing 0.7.0 alarms retain challenge mode and their
settings; new alarms use normal dismissal. No new statistics-sync schema or
consent is introduced. Goals, original sleep proposals and wall-time offsets
remain local. The existing passkey fixes are retained.

## Scope and evidence

| Requirement | Delivered behavior | Automated / visual evidence |
| --- | --- | --- |
| List without global flashing | Per-ID mutation state, serialized native changes, duplicate rejection, current ID lookup inside queue; unchanged polling sends no notification | Controller and home tests cover queued actions, denial, idle polls, neighbor controls and stable widget identity |
| Sorting and add button | Stable local-time order includes disabled alarms; changing time moves its card; nearest date remains independent; accessible FAB above navigation | Home tests cover equal times, disabled toggle, changed time and last-card clearance; 390/320 captures |
| Editor and defaults | Normal / challenge choice, empty optional title, 5-minute snooze, 15-minute budget, 10-second ramp, vibration on, explicit escalation and moving-button opt-in | Model and quick-editor tests cover legacy JSON, defaults, Done/back, disabled unchanged alarm, QR and scheduling failure |
| Normal native alarm | Native Android notification stop and iOS AlarmKit stop work without opening a challenge; ordinary dismissal is recorded separately from emergency | Dart editor/ring tests and native compilation; physical delivery and stop tests remain outstanding |
| Names and system labels | Empty names remain empty; cards/ring omit labels and separators; required system labels use time without modifying the saved title | Model tests and empty-name normal-ring captures |
| Exact input | Ramp 0–60 s, snooze 1–30 min, budget 0–300 min, test 1–60 s/default 20; nap slider 1–180 and input 1–1440; invalid text blocks save | Exact-input, editor, model and native range tests; narrow-screen captures |
| Concise copy | Presets removed; separate advanced controls; short escalation/moving-button copy; snooze count retained without obsolete explanation | Editor and home widget tests and captures |
| One-shot deletion | Default off; reset for repeats; durable final event precedes config cleanup; config revision and native occurrence prevent stale cleanup; previews excluded | Final/emergency versus fire/snooze/failure/timeout tests, failed persistence replay, restart and stale revision tests; Android commits final one-shot state and pending event together |
| Temporary quiet | Android native monotonic 30-second deadline, twice per ring generation; active interval cannot extend; snooze renews budget, process/reboot does not; 2.5-second return | Audio-rule tests cover deadline, boot mismatch, active/exhausted allowance and call priority; Flutter ring/challenge controls remain available |
| Calls and vibration | One Android mixer combines ramp, quiet and system call modes; call suppresses audio and vibration without dismissing; arbitrary focus loss does not imply call; per-alarm vibration persists | Native tests/build and source review; physical cellular/VoIP, routing and vibration checks remain outstanding |
| Challenge progress | Completed stages, mistakes and mixed order persist under occurrence plus native snooze generation; practice has no persisted ring checkpoint | Restore/completion tests and wrong-answer one-stage regression; current unfinished puzzle may regenerate after process death |
| Account | Recovery copy describes passkey loss/rotation; ID reveal/copy separated from actions; explicit logout confirmation; local data retained; deletion describes active storage only | Account interaction tests at 390/320 with 1.5× text, cancellation and confirmed revocation; server assetlinks tests retain both required relations |
| Adaptive icon | Existing clock/5 geometry, separate background/foreground, 72% safe-zone scale and monochrome resource | Android resource compilation; synthetic round and themed previews inspected |
| Sleep source and grouping | Matching fresh manual setup only (up to 36 h, next trigger match ±15 min); no evening-hour or minimum-sleep assumption; manual morning rearm cannot invent bedtime | Matching-alarm/daytime/week-old/rearm tests; source stored separately from edits |
| Sleep event range | SQLite interval query is independent of 500-event UI page; current proposals use the last 54 h | Integration fixture with 552 events retains setup outside the last 500 |
| Wake chains and open form | Adjacent attempts ≤90 min, total chain ≤3 h; prepared different alarms or explicit near-term rearming may join; separate flags take priority; newer end updates untouched form | Multiple-alarm, explicit-split, later-nap and live-form tests; manual times and confirmed entries remain unchanged; already reported occurrences excluded from new home proposal |
| Sleep goals | Optional independent duration and schedule, user-entered values, no assigned norm or alarm edits; local persistence | Goal persistence/no-sync tests; 390/320 settings and chart captures |
| Goal charts and time | Confirmed estimates and source counts, target lines, missing dates without zero values; circular midnight distance; actual duration uses instants; saved endpoint offsets retain local wall time across travel/DST | Midnight and offset-duration tests; old/imported entries without local provenance are excluded from regularity with a visible count; wake times outside ±6 h remain separate duration samples |
| Offline/privacy/update compatibility | Native engines and emergency controls remain independent; no SDK/permission expansion; preview identity and statistics contracts preserved; pinned SDK and lockfile unchanged | Existing alarm/recovery/sync suites, server tests and release package verification |

## Candidate gates

The candidate runs `dart format --output=none --set-exit-if-changed lib test tool`,
`flutter analyze`, `flutter test`, Kotlin tests, server tests and release-metadata
tests. Android APK compilation and the macOS iOS simulator compilation are
mandatory. The complete [0.8.0 CI](https://github.com/Terro216/five-more/actions/runs/42705759927) passed, including iOS simulator compilation on macOS.
The final patch is checked again by CI; results and the exact commit are linked in the release report.
The 0.8.0 source passed formatting, analysis and **210 tests**.
The 0.8.1 correction adds a dedicated Europe/Berlin spring/fall DST regression
run: the actual instant of estimated bedtime is calculated first, and its
own offset is used for wall-clock comparisons. Metadata without a matching bedtime instant is treated as unknown.
The patch passed formatting and analysis, the full 210-test suite, and the
additional enforced DST test (211 distinct Flutter tests across both runs).
The Android implementation passed an arm64 build and **48 native unit tests**;
**9 release-metadata tests** and **27 isolated server tests** also passed.
Synthetic 390/320 captures were rendered and visually inspected.

The GitHub release workflow builds a universal APK, verifies package/version,
three Android ABIs and the established signing certificate, then re-downloads
and compares all uploaded assets before publication. The APK, checksum and
build-info accompany the release. Development APKs are not offered as updates.

Synthetic rendering uses `tool/capture_080.dart` at 390×844 and 320×640 (1.5×
text), with widget coverage for keyboard, scrolling, errors and emergency paths.
It is not evidence of system alarm delivery or physical screen-reader behavior.

Catalog review: runtime components, links, monitoring and backup metadata are
unchanged by this mobile update; no inventory rewrite is needed.

## Physical checks not performed for this candidate

- Install over 0.7.0 with local data retained; ordinary/challenge ringing and
  notification controls without Flutter, including lock screen.
- Speaker/Bluetooth/headset routing; vibration on/off; 1- and 60-second previews;
  ramp and perceptibility of quiet at 40% player level (not measured loudness).
- Quiet before/after snooze, Flutter/service process death, clock change and
  reboot. A reboot conservatively restores sound while preserving spent uses.
- Cellular and VoIP calls already active or arriving during an alarm, rejection
  and ending, process recovery during calls, and OS permission denial.
- Bitwarden registration and repeated sign-in in this APK; actual screen reader
  interaction and launcher themed-icon behavior on a phone.
- iOS AlarmKit delivery, system stop and background behavior on an iPhone.
  Simulator compilation cannot establish these. iOS custom ramp, quiet and
  vibration controls are intentionally not exposed.

A user-reported device check is never inferred from an event or test pass.
Deferred wake checks, tags, location and health integrations are excluded.
No store publication is part of this release.

## Platform references

- [Android AudioManager](https://developer.android.com/reference/android/media/AudioManager): call/communication modes, not arbitrary audio-focus loss.
- [AlarmKit configuration](https://developer.apple.com/documentation/alarmkit/alarmmanager/alarmconfiguration): system-managed alert presentation and sound.
