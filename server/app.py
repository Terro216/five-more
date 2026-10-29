"""Optional sync service. No alarm scheduling or device control lives here."""
from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import secrets
import sqlite3
import time
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
from pathlib import Path
from typing import Any

from cryptography.fernet import Fernet
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import JSONResponse
from webauthn import (generate_registration_options, generate_authentication_options,
                      verify_registration_response, verify_authentication_response, options_to_json)
from webauthn.helpers.structs import AuthenticatorSelectionCriteria, ResidentKeyRequirement, UserVerificationRequirement


@dataclass(frozen=True)
class Config:
    directory: Path
    rp_id: str
    origins: tuple[str, ...]
    data_key: bytes
    audio_account_id: str = ""
    android_fingerprints: tuple[str, ...] = ()
    apple_app_ids: tuple[str, ...] = ()
    metadata_quota: int = 20_000_000
    audio_quota: int = 5_000_000_000
    account_limit: int = 1000

    @classmethod
    def environment(cls):
        rp = os.environ["FIVE_MORE_RP_ID"]
        if not re.fullmatch(r"[a-z0-9.-]+", rp) or "." not in rp:
            raise ValueError("Set a public relying-party domain")
        fingerprints = tuple(filter(None, os.getenv("FIVE_MORE_ANDROID_CERTIFICATES", "").split(",")))
        origins = [f"https://{rp}"]
        for fingerprint in fingerprints:
            raw = bytes.fromhex(fingerprint.replace(":", ""))
            if len(raw) != 32:
                raise ValueError("Invalid signing certificate fingerprint")
            origins.append("android:apk-key-hash:" + base64.urlsafe_b64encode(raw).decode().rstrip("="))
        return cls(Path(os.getenv("FIVE_MORE_DATA_DIR", "/data")), rp, tuple(origins),
                   Path(os.environ["FIVE_MORE_DATA_KEY_FILE"]).read_bytes().strip(),
                   os.getenv("FIVE_MORE_AUDIO_ACCOUNT_ID", ""), fingerprints,
                   tuple(filter(None, os.getenv("FIVE_MORE_APPLE_APP_IDS", "").split(","))))


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def fail(status: int, code: str):
    raise HTTPException(status, code)


class Store:
    def __init__(self, config: Config):
        self.config = config
        self.cipher = Fernet(config.data_key)
        config.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.audio = config.directory / "audio"
        self.audio.mkdir(mode=0o700, exist_ok=True)
        self.path = config.directory / "sync.sqlite3"
        with self.connect() as db:
            db.executescript("""
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS service_metadata(key TEXT PRIMARY KEY, value BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS accounts(id TEXT PRIMARY KEY, recovery TEXT UNIQUE NOT NULL, created INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS credentials(id TEXT PRIMARY KEY, account TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, public_key BLOB NOT NULL, counter INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS sessions(hash TEXT PRIMARY KEY, id TEXT UNIQUE NOT NULL, account TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, created INTEGER NOT NULL, expires INTEGER NOT NULL, name TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS challenges(id TEXT PRIMARY KEY, challenge BLOB NOT NULL, mode TEXT NOT NULL, account TEXT NOT NULL, expires INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS limits(key TEXT PRIMARY KEY, window INTEGER NOT NULL, count INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS records(seq INTEGER PRIMARY KEY AUTOINCREMENT, account TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, kind TEXT NOT NULL, id TEXT NOT NULL, data BLOB NOT NULL, at INTEGER NOT NULL, revision INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, bytes INTEGER NOT NULL, UNIQUE(account,kind,id));
                CREATE INDEX IF NOT EXISTS records_account_time ON records(account,kind,at DESC,id DESC);
                CREATE TABLE IF NOT EXISTS audio(account TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, id TEXT NOT NULL, file TEXT NOT NULL UNIQUE, bytes INTEGER NOT NULL, sha TEXT NOT NULL, PRIMARY KEY(account,id));
            """)
            check = db.execute("SELECT value FROM service_metadata WHERE key = 'encryption_check'").fetchone()
            if check is None:
                db.execute("INSERT INTO service_metadata VALUES('encryption_check',?)", (self.cipher.encrypt(b"five_more_v1"),))
            elif self.cipher.decrypt(check["value"]) != b"five_more_v1":
                raise ValueError("Invalid storage key")
        os.chmod(self.path, 0o600)

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=15)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        try:
            with db:
                yield db
        finally:
            db.close()

    def pack(self, data):
        return self.cipher.encrypt(json.dumps(data, separators=(",", ":"), ensure_ascii=False).encode())

    def unpack(self, row):
        return {"kind": row["kind"], "id": row["id"], "at": row["at"], "revision": row["revision"],
                "deleted": bool(row["deleted"]), "data": json.loads(self.cipher.decrypt(row["data"]))}

    def session(self, db, account, name="Телефон"):
        token = secrets.token_urlsafe(32)
        now = int(time.time())
        session_id = str(uuid.uuid4())
        db.execute("DELETE FROM sessions WHERE expires <= ?", (now,))
        if db.execute("SELECT COUNT(*) FROM sessions WHERE account = ?", (account,)).fetchone()[0] >= 64:
            fail(429, "too_many_sessions")
        db.execute("INSERT INTO sessions VALUES(?,?,?,?,?,?)", (digest(token), session_id, account, now, now + 90 * 86400, str(name)[:60]))
        return {"token": token, "sessionId": session_id, "accountId": account,
                "audioAllowed": account == self.config.audio_account_id, "expiresAt": (now + 90 * 86400) * 1000}

    def authenticated(self, request):
        header = request.headers.get("authorization", "")
        if not header.startswith("Bearer ") or len(header) > 200:
            fail(401, "sign_in_required")
        with self.connect() as db:
            row = db.execute("SELECT * FROM sessions WHERE hash = ? AND expires > ?", (digest(header[7:]), int(time.time()))).fetchone()
        if row is None:
            fail(401, "sign_in_required")
        return row

    def challenge(self, mode, account, challenge):
        identifier = secrets.token_urlsafe(32)
        with self.connect() as db:
            db.execute("DELETE FROM challenges WHERE expires < ?", (int(time.time()),))
            if db.execute("SELECT COUNT(*) FROM challenges").fetchone()[0] >= 10000:
                fail(429, "try_later")
            db.execute("INSERT INTO challenges VALUES(?,?,?,?,?)", (identifier, challenge, mode, account, int(time.time()) + 300))
        return identifier

    def consume(self, identifier, mode):
        if not isinstance(identifier, str):
            fail(400, "invalid_challenge")
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM challenges WHERE id = ?", (identifier,)).fetchone()
            db.execute("DELETE FROM challenges WHERE id = ?", (identifier,))
        if row is None or row["mode"] != mode or row["expires"] < time.time():
            fail(400, "invalid_challenge")
        return row


def valid_record(raw):
    if not isinstance(raw, dict) or set(raw) != {"kind", "id", "data", "revision", "deleted"}:
        fail(422, "invalid_record")
    kind, identifier, data = raw["kind"], raw["id"], raw["data"]
    if kind not in ("event", "sleep", "note") or not isinstance(identifier, str) or not re.fullmatch(r"[a-zA-Z0-9:_.-]{1,150}", identifier):
        fail(422, "invalid_record")
    if not isinstance(data, dict) or len(json.dumps(data)) > 8192 or type(raw["revision"]) is not int or raw["revision"] < 0 or type(raw["deleted"]) is not bool:
        fail(422, "invalid_record")
    allowed = {
        "event": {"eventId", "id", "occurrenceId", "type", "at", "snoozesUsed", "snoozedMinutes", "nextAt"},
        "sleep": {"occurrenceId", "wokeAt", "bedAt", "sleepQuality", "wakeQuality", "occurrences", "bedSource", "wakeSource", "separate"},
        "note": {"file", "at", "seconds"},
    }[kind]
    if set(data) - allowed:
        fail(422, "unexpected_fields")
    id_field = {"event": "eventId", "sleep": "occurrenceId", "note": "file"}[kind]
    if data.get(id_field) != identifier:
        fail(422, "invalid_record_id")
    at = data.get("wokeAt" if kind == "sleep" else "at")
    if type(at) is not int or not 0 <= at <= 4133980800000:
        fail(422, "invalid_time")
    if kind == "event":
        if not isinstance(data.get("id"), str) or not isinstance(data.get("occurrenceId"), str) or data["id"].startswith("preview:"):
            fail(422, "preview_or_invalid_event")
        if data.get("type") not in {"armed", "fired", "ringing", "snoozed", "dismissed", "emergency", "emergency_dismissed", "timed_out", "cancelled", "missed", "schedule_failed"}:
            fail(422, "invalid_event_type")
        for field in ("snoozesUsed", "snoozedMinutes"):
            if type(data.get(field, 0)) is not int or not 0 <= data.get(field, 0) <= 100000:
                fail(422, "invalid_counter")
        if any(len(data[k]) > 150 for k in ("id", "occurrenceId")):
            fail(422, "invalid_record_id")
        if data.get("nextAt") is not None and (type(data["nextAt"]) is not int or not 0 <= data["nextAt"] <= 4133980800000):
            fail(422, "invalid_time")
        if raw["deleted"]:
            fail(422, "events_are_immutable")
    if kind == "sleep":
        if type(data.get("bedAt")) is not int or not 0 < at - data["bedAt"] <= 48 * 3600000:
            fail(422, "invalid_sleep_interval")
        if any(type(data.get(k)) is not int or not 1 <= data[k] <= 5 for k in ("sleepQuality", "wakeQuality")):
            fail(422, "invalid_rating")
        occurrences = data.get("occurrences", [])
        if not isinstance(occurrences, list) or len(occurrences) > 300 or any(not isinstance(o, str) or not re.fullmatch(r"[a-zA-Z0-9:_.-]{1,150}", o) for o in occurrences):
            fail(422, "invalid_sleep_members")
        if data.get("bedSource", "manual") not in {"manual", "habit", "alarm_setup"} or data.get("wakeSource", "alarm") not in {"manual", "alarm"} or type(data.get("separate", False)) is not bool:
            fail(422, "invalid_sleep_provenance")
    if kind == "note":
        if not re.fullmatch(r"[a-fA-F0-9-]{36}\.m4a", identifier) or type(data.get("seconds")) is not int or not 0 <= data["seconds"] <= 86400:
            fail(422, "invalid_audio")
    return at


def create_app(config: Config | None = None):
    config = config or Config.environment()
    store = Store(config)
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    app.state.store = store

    @app.middleware("http")
    async def boundaries(request, call_next):
        audio = request.url.path.startswith("/v1/audio/")
        maximum = 20_000_000 if audio else 512_000
        try:
            if int(request.headers.get("content-length", "0")) > maximum:
                return JSONResponse({"detail": "request_too_large"}, 413)
        except ValueError:
            return JSONResponse({"detail": "invalid_length"}, 400)
        if audio:
            try:
                identity = store.authenticated(request)
                if identity["account"] != config.audio_account_id:
                    fail(403, "audio_not_enabled")
            except HTTPException as error:
                return JSONResponse({"detail": error.detail}, error.status_code)
        # Read a bounded stream, including chunked requests without Content-Length.
        body = bytearray()
        async for chunk in request.stream():
            body.extend(chunk)
            if len(body) > maximum:
                return JSONResponse({"detail": "request_too_large"}, 413)
        request._body = bytes(body)
        ip = request.client.host if request.client else "unknown"
        bucket = "auth" if request.url.path.startswith("/v1/auth/") else "api"
        key, window = digest(ip + bucket), int(time.time()) // 60
        with store.connect() as db:
            db.execute("DELETE FROM limits WHERE window < ?", (window - 1,))
            db.execute("INSERT INTO limits VALUES(?,?,1) ON CONFLICT(key) DO UPDATE SET count = CASE WHEN window = excluded.window THEN count + 1 ELSE 1 END, window = excluded.window", (key, window))
            count = db.execute("SELECT count FROM limits WHERE key = ?", (key,)).fetchone()[0]
        if count > (30 if bucket == "auth" else 600):
            return JSONResponse({"detail": "try_later"}, 429, headers={"Retry-After": "60"})
        try:
            response = await call_next(request)
        except (json.JSONDecodeError, UnicodeDecodeError, KeyError, TypeError, ValueError):
            response = JSONResponse({"detail": "invalid_request"}, 400)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        return response

    @app.get("/healthz")
    def health():
        return {"ok": True}

    @app.get("/.well-known/assetlinks.json")
    def assetlinks():
        return [{"relation": ["delegate_permission/common.get_login_creds"], "target": {
            "namespace": "android_app", "package_name": "dev.ilyamedve.fivemore", "sha256_cert_fingerprints": list(config.android_fingerprints)}}]

    @app.get("/.well-known/apple-app-site-association")
    def association():
        return {"webcredentials": {"apps": list(config.apple_app_ids)}}

    @app.post("/v1/auth/register/options")
    async def register_options(request: Request):
        account = str(uuid.uuid4())
        mode = "register"
        if request.headers.get("authorization"):
            account = store.authenticated(request)["account"]
            mode = "add"
        options = generate_registration_options(rp_id=config.rp_id, rp_name="Ещё пять", user_id=account.encode(), user_name=f"Ещё пять · {account[:8]}",
            authenticator_selection=AuthenticatorSelectionCriteria(resident_key=ResidentKeyRequirement.REQUIRED, user_verification=UserVerificationRequirement.REQUIRED))
        identifier = store.challenge(mode, account, options.challenge)
        return {"challengeId": identifier, "options": json.loads(options_to_json(options))}

    @app.post("/v1/auth/register/verify")
    async def register_verify(request: Request):
        body = await request.json()
        mode = "add" if request.headers.get("authorization") else "register"
        session = store.authenticated(request) if mode == "add" else None
        challenge = store.consume(body.get("challengeId"), mode)
        if session is not None and session["account"] != challenge["account"]:
            fail(403, "wrong_account")
        try:
            verified = verify_registration_response(credential=body["credential"], expected_challenge=challenge["challenge"], expected_rp_id=config.rp_id,
                expected_origin=list(config.origins), require_user_verification=True)
        except Exception:
            fail(400, "passkey_verification_failed")
        account = challenge["account"]
        recovery = secrets.token_urlsafe(32)
        with store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            if mode == "add" and db.execute("SELECT 1 FROM sessions WHERE hash = ? AND expires > ?", (session["hash"], int(time.time()))).fetchone() is None:
                fail(401, "sign_in_required")
            if mode == "register":
                if db.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] >= config.account_limit:
                    fail(503, "registration_capacity")
                db.execute("INSERT INTO accounts VALUES(?,?,?)", (account, digest(recovery), int(time.time())))
            if db.execute("SELECT COUNT(*) FROM credentials WHERE account = ?", (account,)).fetchone()[0] >= 10:
                fail(429, "too_many_passkeys")
            credential_id = base64.urlsafe_b64encode(verified.credential_id).decode().rstrip("=")
            try:
                db.execute("INSERT INTO credentials VALUES(?,?,?,?)", (credential_id, account, verified.credential_public_key, verified.sign_count))
            except sqlite3.IntegrityError:
                fail(409, "credential_already_registered")
            if mode == "add":
                return {"ok": True}
            result = store.session(db, account, body.get("deviceName", "Телефон"))
        return {**result, "recoveryKey": recovery}

    @app.post("/v1/auth/login/options")
    def login_options():
        options = generate_authentication_options(rp_id=config.rp_id, user_verification=UserVerificationRequirement.REQUIRED)
        return {"challengeId": store.challenge("login", "", options.challenge), "options": json.loads(options_to_json(options))}

    @app.post("/v1/auth/login/verify")
    async def login_verify(request: Request):
        body = await request.json()
        challenge = store.consume(body.get("challengeId"), "login")
        credential = body["credential"]
        with store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            stored = db.execute("SELECT * FROM credentials WHERE id = ?", (credential.get("id"),)).fetchone()
            if stored is None:
                fail(400, "passkey_verification_failed")
            try:
                verified = verify_authentication_response(credential=credential, expected_challenge=challenge["challenge"], expected_rp_id=config.rp_id,
                    expected_origin=list(config.origins), credential_public_key=stored["public_key"], credential_current_sign_count=stored["counter"], require_user_verification=True)
                handle = credential.get("response", {}).get("userHandle")
                if handle and base64.urlsafe_b64decode(handle + "=" * (-len(handle) % 4)).decode() != stored["account"]:
                    fail(400, "passkey_verification_failed")
            except Exception:
                fail(400, "passkey_verification_failed")
            if body.get("expectedAccountId") not in (None, stored["account"]):
                fail(403, "wrong_account")
            db.execute("UPDATE credentials SET counter = ? WHERE id = ?", (verified.new_sign_count, stored["id"]))
            return store.session(db, stored["account"], body.get("deviceName", "Телефон"))

    @app.post("/v1/auth/recover")
    async def recover(request: Request):
        body = await request.json()
        key = body.get("recoveryKey", "")
        if not isinstance(key, str) or not 40 <= len(key) <= 100:
            fail(401, "invalid_recovery_key")
        next_key = secrets.token_urlsafe(32)
        with store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            account = db.execute("SELECT id FROM accounts WHERE recovery = ?", (digest(key),)).fetchone()
            if account is None:
                fail(401, "invalid_recovery_key")
            account = account["id"]
            if body.get("expectedAccountId") not in (None, account):
                fail(403, "wrong_account")
            db.execute("UPDATE accounts SET recovery = ? WHERE id = ?", (digest(next_key), account))
            db.execute("DELETE FROM sessions WHERE account = ?", (account,))
            # A lost device may still have a passkey. Recovery revokes all old keys.
            db.execute("DELETE FROM credentials WHERE account = ?", (account,))
            return {**store.session(db, account, body.get("deviceName", "Телефон")), "recoveryKey": next_key}

    @app.get("/v1/account")
    def account(request: Request):
        session = store.authenticated(request)
        with store.connect() as db:
            sessions = [dict(r) for r in db.execute("SELECT id,name,created,expires FROM sessions WHERE account = ? AND expires > ? ORDER BY created DESC", (session["account"], int(time.time())))]
        return {"accountId": session["account"], "audioAllowed": session["account"] == config.audio_account_id, "sessions": sessions}

    @app.delete("/v1/sessions/{identifier}")
    def revoke(identifier: str, request: Request):
        session = store.authenticated(request)
        with store.connect() as db:
            db.execute("DELETE FROM sessions WHERE id = ? AND account = ?", (identifier, session["account"]))
        return {"ok": True}

    @app.post("/v1/sync")
    async def sync(request: Request):
        account = store.authenticated(request)["account"]
        body = await request.json()
        records = body.get("records")
        if not isinstance(records, list) or len(records) > 100:
            fail(422, "invalid_batch")
        validated = [(r, valid_record(r)) for r in records]
        if any(r["kind"] == "note" and not r["deleted"] for r, _ in validated) and account != config.audio_account_id:
            fail(403, "audio_not_enabled")
        accepted, conflicts, remove_audio = [], [], []
        with store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            total = db.execute("SELECT COALESCE(SUM(bytes),0) FROM records WHERE account = ?", (account,)).fetchone()[0]
            for raw, at in validated:
                old = db.execute("SELECT * FROM records WHERE account = ? AND kind = ? AND id = ?", (account, raw["kind"], raw["id"])).fetchone()
                if old:
                    existing = store.unpack(old)
                    if existing["data"] == raw["data"] and existing["deleted"] == raw["deleted"]:
                        accepted.append({"kind": raw["kind"], "id": raw["id"], "revision": old["revision"]})
                        continue
                    if raw["kind"] == "event" or old["revision"] != raw["revision"]:
                        conflicts.append(existing)
                        continue
                elif raw["revision"] != 0:
                    fail(409, "missing_base_revision")
                data = store.pack(raw["data"])
                total += len(data) - (old["bytes"] if old else 0)
                if total > config.metadata_quota:
                    fail(413, "storage_quota")
                revision = old["revision"] + 1 if old else 1
                # A fresh sequence on every update makes cursor pagination reliable.
                if old:
                    db.execute("DELETE FROM records WHERE seq = ?", (old["seq"],))
                db.execute("INSERT INTO records(account,kind,id,data,at,revision,deleted,bytes) VALUES(?,?,?,?,?,?,?,?)", (account, raw["kind"], raw["id"], data, at, revision, int(raw["deleted"]), len(data)))
                if raw["kind"] == "note" and raw["deleted"]:
                    audio_row = db.execute("SELECT file FROM audio WHERE account = ? AND id = ?", (account, raw["id"])).fetchone()
                    db.execute("DELETE FROM audio WHERE account = ? AND id = ?", (account, raw["id"]))
                    if audio_row:
                        remove_audio.append(store.audio / audio_row["file"])
                accepted.append({"kind": raw["kind"], "id": raw["id"], "revision": revision})
        for path in remove_audio:
            path.unlink(missing_ok=True)
        return {"accepted": accepted, "conflicts": conflicts}

    @app.get("/v1/changes")
    def changes(request: Request, cursor: int = 0):
        account = store.authenticated(request)["account"]
        if cursor < 0:
            fail(422, "invalid_cursor")
        with store.connect() as db:
            rows = db.execute("SELECT * FROM records WHERE account = ? AND seq > ? ORDER BY seq LIMIT 201", (account, cursor)).fetchall()
        page = rows[:200]
        return {"records": [store.unpack(r) for r in page], "cursor": page[-1]["seq"] if page else cursor, "more": len(rows) > 200}

    @app.get("/v1/bootstrap")
    def bootstrap(request: Request):
        account = store.authenticated(request)["account"]
        with store.connect() as db:
            db.execute("BEGIN")
            cursor = db.execute("SELECT COALESCE(MAX(seq),0) FROM records WHERE account = ?", (account,)).fetchone()[0]
            rows = db.execute("SELECT * FROM records WHERE account = ? AND kind = 'event' ORDER BY at DESC,id DESC LIMIT 500", (account,)).fetchall()
            rows += db.execute("SELECT * FROM records WHERE account = ? AND kind != 'event' ORDER BY at DESC,id DESC", (account,)).fetchall()
        return {"records": [store.unpack(r) for r in rows], "cursor": cursor}

    @app.get("/v1/history")
    def history(request: Request, before_at: int = 4133980800001, before_id: str = "~", start: int = 0, end: int = 4133980800001):
        account = store.authenticated(request)["account"]
        with store.connect() as db:
            rows = db.execute("SELECT * FROM records WHERE account = ? AND kind = 'event' AND deleted = 0 AND at >= ? AND at < ? AND (at < ? OR (at = ? AND id < ?)) ORDER BY at DESC,id DESC LIMIT 101", (account, start, end, before_at, before_at, before_id)).fetchall()
        return {"records": [store.unpack(r) for r in rows[:100]], "more": len(rows) > 100}

    @app.get("/v1/summary")
    def summary(request: Request, start: int = 0, end: int = 4133980800001, offset_minutes: int = 0, time_zone: str = ""):
        account = store.authenticated(request)["account"]
        if not 0 <= start < end <= 4133980800001 or not -840 <= offset_minutes <= 840:
            fail(422, "invalid_period")
        try:
            zone = ZoneInfo(time_zone) if time_zone else None
        except (ZoneInfoNotFoundError, ValueError):
            fail(422, "invalid_time_zone")
        with store.connect() as db:
            rows = db.execute("SELECT * FROM records WHERE account = ? AND deleted = 0 AND kind IN ('event','sleep') AND at >= ? AND at < ? ORDER BY at,id", (account, start - 86400000, end)).fetchall()
        groups, days, sleep, outcomes = {}, {}, {}, [0, 0, 0]
        snoozes = 0
        def day(at):
            if zone is not None:
                return datetime.fromtimestamp(at / 1000, timezone.utc).astimezone(zone).strftime("%Y-%m-%d")
            return time.strftime("%Y-%m-%d", time.gmtime((at + offset_minutes * 60000) / 1000))
        for row in rows:
            data = store.unpack(row)["data"]
            if row["kind"] == "sleep":
                if row["at"] < start:
                    continue
                bucket = sleep.setdefault(day(row["at"]), [])
                bucket.append(data)
            else:
                groups.setdefault((data["id"], data["occurrenceId"]), []).append(data)
                if data["type"] == "snoozed" and row["at"] >= start:
                    key = day(row["at"])
                    days[key] = days.get(key, 0) + 1
                    snoozes += 1
        wake = {}
        for group in groups.values():
            finish = next((e for e in reversed(group) if e["type"] in {"dismissed", "emergency", "emergency_dismissed", "timed_out", "missed"}), None)
            begin = next((e for e in group if e["type"] in {"fired", "ringing"}), None)
            if not finish or finish["at"] < start:
                continue
            category = 0 if finish["type"] == "dismissed" else 1 if finish["type"] in {"emergency", "emergency_dismissed"} else 2
            outcomes[category] += 1
            if category == 0 and begin and begin["at"] <= finish["at"]:
                wake.setdefault(day(finish["at"]), []).append((finish["at"] - begin["at"]) / 60000)
        return {"snoozes": snoozes, "outcomes": outcomes,
                "snoozeDays": [{"day": k, "value": v} for k, v in sorted(days.items())],
                "wakeDays": [{"day": k, "value": sum(v) / len(v), "samples": len(v)} for k, v in sorted(wake.items())],
                "sleepDays": [{"day": k, "hours": sum((e["wokeAt"] - e["bedAt"]) / 3600000 for e in v) / len(v),
                               "sleepQuality": sum(e["sleepQuality"] for e in v) / len(v), "wakeQuality": sum(e["wakeQuality"] for e in v) / len(v), "samples": len(v)} for k, v in sorted(sleep.items())]}

    @app.put("/v1/audio/{identifier}")
    async def upload_audio(identifier: str, request: Request):
        account = store.authenticated(request)["account"]
        if account != config.audio_account_id:
            fail(403, "audio_not_enabled")
        if not re.fullmatch(r"[a-fA-F0-9-]{36}\.m4a", identifier):
            fail(422, "invalid_audio")
        data = await request.body()
        if len(data) < 12 or data[4:8] != b"ftyp":
            fail(422, "invalid_audio")
        sha = hashlib.sha256(data).hexdigest()
        with store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            note = db.execute("SELECT 1 FROM records WHERE account = ? AND kind = 'note' AND id = ? AND deleted = 0", (account, identifier)).fetchone()
            if note is None:
                fail(404, "note_not_found")
            old = db.execute("SELECT * FROM audio WHERE account = ? AND id = ?", (account, identifier)).fetchone()
            if old:
                if old["sha"] != sha:
                    fail(409, "audio_is_immutable")
                return {"ok": True, "sha256": sha}
            size = db.execute("SELECT COALESCE(SUM(bytes),0) FROM audio WHERE account = ?", (account,)).fetchone()[0]
            if size + len(data) > config.audio_quota:
                fail(413, "audio_quota")
            name = secrets.token_hex(32)
            destination = store.audio / name
            with destination.open("xb") as file:
                os.chmod(destination, 0o600)
                file.write(store.cipher.encrypt(data))
                file.flush()
                os.fsync(file.fileno())
            try:
                db.execute("INSERT INTO audio VALUES(?,?,?,?,?)", (account, identifier, name, len(data), sha))
            except Exception:
                destination.unlink(missing_ok=True)
                raise
        return {"ok": True, "sha256": sha}

    @app.get("/v1/audio/{identifier}")
    def download_audio(identifier: str, request: Request):
        account = store.authenticated(request)["account"]
        if account != config.audio_account_id:
            fail(403, "audio_not_enabled")
        with store.connect() as db:
            row = db.execute("SELECT * FROM audio WHERE account = ? AND id = ?", (account, identifier)).fetchone()
        if row is None:
            fail(404, "audio_not_found")
        return Response(store.cipher.decrypt((store.audio / row["file"]).read_bytes()), media_type="audio/mp4")

    @app.delete("/v1/account")
    def delete_account(request: Request):
        session = store.authenticated(request)
        if session["created"] < time.time() - 300:
            fail(403, "fresh_sign_in_required")
        with store.connect() as db:
            rows = db.execute("SELECT file FROM audio WHERE account = ?", (session["account"],)).fetchall()
            db.execute("DELETE FROM accounts WHERE id = ?", (session["account"],))
        for row in rows:
            (store.audio / row["file"]).unlink(missing_ok=True)
        return {"ok": True}

    return app
