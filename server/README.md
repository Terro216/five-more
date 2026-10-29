# Optional history service

This service stores history and sleep reviews. Native alarms never depend on it.
The mobile app synchronizes while open, retries failures, and pauses requests
during ringing. Synchronization is optional; it is off until account setup.
The browser build is only a UI/challenge preview and does not sign in.

## Identity and privacy

An account uses discoverable passkeys, with user verification required, and a
separate random recovery key. There is no email or password. Recovery rotates
the recovery key and revokes **all sessions and previous passkeys**. Add a new
passkey after recovery. If both passkeys and the recovery key are lost, access
cannot be restored. Session tokens expire after 90 days and can be revoked.
Keys and tokens are not logged. Only token/recovery hashes are stored by the API.
The phone stores its token in Android secure storage or iOS Keychain.

The server **can read statistics and audio**. TLS protects transport; a separate
server key encrypts record payloads and audio files at rest. This is not
end-to-end encryption. Account IDs, event timestamps, revision metadata and
public passkey material remain readable in SQLite. Host access together with
the server key gives access to the payloads. No tracking SDK is configured.

Audio is denied by default. Set `FIVE_MORE_AUDIO_ACCOUNT_ID` to the exact account
ID after that account has been created. No client flag, first-registration rule,
or recovery request grants this permission. The permitted account must also
enable the audio switch in the app. Other accounts upload only event and sleep
records. Disabling uploads does not delete existing server copies. Removing a
voice note queues its server deletion even with the upload switch off.

Local history remains associated with one account after logout, preventing an
accidental upload into a different account. Local alarms, alarm titles, QR
secrets, ringtone files and device-check answers are not sent to this service.

## Configuration

Run `server.app:create_app` as a Uvicorn factory, or build this directory's
Dockerfile. Python dependencies are pinned in `requirements.txt`.

| Variable | Meaning |
| --- | --- |
| `FIVE_MORE_RP_ID` | Permanent public HTTPS hostname used for passkeys, without a path |
| `FIVE_MORE_DATA_DIR` | Persistent private data directory; container default `/data` |
| `FIVE_MORE_DATA_KEY_FILE` | Read-only file containing a Fernet key, outside source and image |
| `FIVE_MORE_ANDROID_CERTIFICATES` | Comma-separated SHA-256 signing certificate fingerprints |
| `FIVE_MORE_APPLE_APP_IDS` | Comma-separated `TeamID.BundleID` identifiers |
| `FIVE_MORE_AUDIO_ACCOUNT_ID` | The one account permitted to sync audio; empty means none |
| `FORWARDED_ALLOW_IPS` | Only the actual trusted TLS proxy IPs, never `*` on an exposed service |

Terminate TLS at the deployment's proxy; do not expose port 8080 directly to the
internet. Preserve Authorization headers, set a request body limit of 20 MB and
request timeouts, and disable body/header logging. Serve the two `.well-known`
association files without redirects. Use the existing backup system for SQLite
and audio, with the encryption key kept separately. A deployment is not ready
until an isolated restore has been verified. Site-specific addresses, keys and
recovery instructions must remain outside this public repository.

The image runs as UID 10001. Mount its data directory writable by that UID and
the key read-only. Use a read-only root filesystem, a temporary `/tmp`, dropped
capabilities, `no-new-privileges`, and explicit memory/process limits. Keep one
worker for this SQLite service. There is no production Compose file or automatic
deployment in this repository.

Build the mobile app with `--dart-define=FIVE_MORE_SYNC_URL=https://<hostname>`.
Android also requires the matching signing certificate in Digital Asset Links.
For iOS, set the Xcode build setting `FIVE_MORE_PASSKEY_DOMAIN` to that hostname
and enable Associated Domains in the signing profile; the source default is
`example.invalid`. Configure the Apple app ID on the server before installation.
Passkeys require Android 9+ or iOS; local alarms still support Android 8+.
Do not distribute a sync-enabled build before both association checks pass.

## Data contract and future analysis

All authenticated queries are scoped to the account in the session. The API
does not accept a client-selected owner. Limits are 20 MB of encrypted metadata
per account, 5 GB of audio for the permitted account and 20 MB per audio file.
Limits return errors without discarding the local copy.

- `event`: immutable native `eventId`, alarm `id`, `occurrenceId`, UTC epoch
  milliseconds `at`, event `type`, `snoozesUsed`, `snoozedMinutes`, optional
  `nextAt`. Preview occurrences are rejected.
- `sleep`: `occurrenceId` identifies the night, with its member `occurrences`,
  estimated `bedAt`, `wokeAt`, 1–5 sleep/wake ratings and provenance
  (`bedSource`, `wakeSource`). Manual times are not measured sleep. Separate
  nights are explicit. This is the boundary for a future Health Atlas adapter;
  no automatic PDW sharing is enabled.
- `note`: UUID `.m4a` filename, creation time and duration in seconds. Audio
  bytes live in private encrypted files and are downloaded only on playback.

`POST /v1/sync` accepts at most 100 records with base revisions. Event replays
are idempotent; mutable conflicts are returned for an explicit client decision.
Deletes are tombstones. `GET /v1/changes?cursor=…` pages committed changes.
The initial `/v1/bootstrap` returns the latest 500 events and all sleep/note
metadata at a consistent cursor; `/v1/history` pages older events by `(at,id)`.
`/v1/summary` aggregates the **entire selected period**, independently of
history page limits. The client can cache these aggregates for offline viewing.
`DELETE /v1/account` requires a sign-in within the last five minutes and deletes
the account's live records/audio. Backup retention is deployment policy.

## Verification

```sh
python -m pip install -r server/requirements.txt
python -m unittest discover -s server/tests -v
```

Tests use temporary databases and real synthetic WebAuthn signatures: replay,
origin, user-verification, recovery, cross-account access, encryption, audio
permissions, quotas, atomic batches, revision conflicts and pagination.
These tests do not prove passkey enrollment on a physical phone or TLS/backup
configuration in a live deployment. `/healthz` is a liveness check only.
