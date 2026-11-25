# Follow-up: challenges, sleep review, photo framing and countdown

Changes prepared for the next app release; no store publication is implied.

- Mirror phrases: fetch a rotating selection of authors, books and films from
  the Russian Wikiquote API. Mobile also reads the book and film sections of
  Citaty.info and offers quotes.to.digital as a separate opt-in. Save the work
  or author and a source URL with each quote. Refresh is manual. Successful
  sources wait 24 hours before another fetch. A failing source leaves saved
  quotes and the successful parts of the new batch available offline.
- Memory: feedback stays visible above the task. Practice shows incorrect and
  missed cells, with an explicit retry; repeat viewing is available at every
  practice difficulty. A wrong answer still returns exactly one stage.
- Shake: easy/normal/hard/extreme require 12/28/60/100 direction changes;
  normal/hard/extreme also require 8/20/40 seconds. Force threshold stays the same.
- Sleep: an alarm set less than three hours before ringing cannot supply an
  inferred bedtime. Short sleep times can be entered manually. Previously
  confirmed records are preserved. Sleep and waking ratings have separate labels.
- Home offers only the latest sleep review, dated and timed. Saving or skipping
  it does not expose older prompts. The sleep diary contains saved reviews and
  recent completed wake-ups, with explicit selection and bulk skip. This is
  limited to the controller's recent event window for unreviewed wake-ups;
  saved reviews remain available regardless of their age.
- Separate sleep: explicitly asks when the person fell asleep again before
  splitting the last wake-up into a new record. Existing confirmed records do
  not offer an ambiguous split that could duplicate a saved sleep interval.
- Optional text notes are saved locally in SQLite journal settings and can be
  edited in the diary. They are not added to the statistics-sync contract.
- Clock sheet: space between the dial and the confirmation button.
- Photo framing: optional translucent clock/control guide does not intercept
  gestures. It is an approximate layout guide; actual layout adapts to screen
  size, accessibility text size, alarm mode and snooze settings.
- Android: a dismissible notification shows the next real scheduled or snoozed
  alarm. Android renders its countdown; there is no periodic application timer,
  extra wake lock, polling service or new network work. Dismissal is persisted
  for that occurrence and scheduled time, including across reboot. A new
  occurrence or time edit can show it again. Real ringing hides the countdown;
  test alarms are excluded. It has a separate notification channel. Notification
  errors cannot turn scheduling or dismissal into a failure.

Validation results are reported separately from physical-device behavior.
Device checks still needed: real accelerometer effort; OEM notification display
and swipe/reboot persistence; ringing and snoozing without Flutter; photo guide
against the actual phone's layout. A development-signed APK is compilation evidence,
not an update for an existing signed installation.

## Verification

- Formatter and `flutter analyze`: passed.
- Full Flutter suite: 247 passed, one environment-gated DST test skipped; the
  DST test was then run explicitly in the required timezone and passed.
- After the final helper-text layout adjustment: 10 targeted sleep/challenge
  tests passed, and the formatter and analyzer passed again.
- Android native tests: 55 passed, no failures, errors or skips.
- Android arm64 release-mode APK: built with development signing.
- 52 synthetic UI captures: dark/light themes, 390×844 and 320×640, with
  1.5× text at the narrow size. Photo gestures, review layouts and error
  feedback were inspected. These captures do not validate hardware behavior.
- No physical-phone checks, signed-update release or store publication were
  performed for that build.

## Verification for 0.8.5

- Live downloads through the Dart client returned 48 Wikiquote excerpts,
  27 book and film quotes from Citaty.info, and four from quotes.to.digital
  in one run. The browser CORS check passed for Wikiquote.
- Format and analysis passed. 250 Flutter tests passed, and the separately
  enabled DST test passed. All 55 Android native tests passed.
- The web build and a development-signed universal Android APK built
  successfully. Package identity, version, ABI set, APK signature and the
  copied archive's SHA-256 were checked.
- Quote settings and source details were rendered and inspected at 320 and
  390 px, including 1.5× text. No physical-device testing was performed.
