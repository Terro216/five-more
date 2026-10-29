import json
import sqlite3
import tempfile
import unittest
import uuid
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

from cryptography.fernet import Fernet, InvalidToken
from fastapi.testclient import TestClient

from server.app import Config, create_app
from server.backup import archive_lock, create_snapshot, restore, verify
from server import backup
from server.tests.test_api import Authenticator


class BackupTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / "live"
        self.archive = self.root / "backup"
        self.key = Fernet.generate_key()
        self.config = Config(self.source, "sync.example.test", ("https://sync.example.test",), self.key)
        self.app = create_app(self.config)
        self.client = TestClient(self.app)
        options = self.client.post("/v1/auth/register/options").json()
        identity = self.client.post("/v1/auth/register/verify", json={"challengeId": options["challengeId"], "credential": Authenticator().registration(options["options"])}).json()
        self.headers = {"Authorization": "Bearer " + identity["token"]}
        self.client.close()
        self.config = replace(self.config, audio_account_id=identity["accountId"])
        self.app = create_app(self.config)
        self.client = TestClient(self.app)
        self.note = str(uuid.uuid4()) + ".m4a"
        self.payload = {"kind": "note", "id": self.note, "revision": 0, "deleted": False, "data": {"file": self.note, "at": 1793200000000, "seconds": 30}}
        self.assertEqual(self.client.post("/v1/sync", headers=self.headers, json={"records": [self.payload]}).status_code, 200)
        self.audio = b"1234ftypM4A " + b"synthetic-private-audio" * 10
        self.assertEqual(self.client.put("/v1/audio/" + self.note, headers=self.headers, content=self.audio).status_code, 200)

    def tearDown(self):
        self.client.close()
        self.temporary.cleanup()

    def snapshot(self, keep=14):
        return create_snapshot(self.source, self.archive, self.key, keep=keep)

    def delete_note(self):
        self.payload.update(revision=1, deleted=True)
        self.assertEqual(self.client.post("/v1/sync", headers=self.headers, json={"records": [self.payload]}).status_code, 200)

    def test_isolated_restore_preserves_login_history_and_audio_with_separate_key(self):
        expected = self.client.get("/v1/bootstrap", headers=self.headers).json()
        summary = self.client.get("/v1/summary", headers=self.headers).json()
        snapshot = self.snapshot()
        self.assertEqual(verify(self.archive, snapshot["id"], self.key), snapshot)
        self.delete_note()
        destination = self.root / "restored"
        restore(self.archive, snapshot["id"], destination, self.key)
        with TestClient(create_app(replace(self.config, directory=destination))) as client:
            self.assertEqual(client.get("/v1/bootstrap", headers=self.headers).json(), expected)
            self.assertEqual(client.get("/v1/summary", headers=self.headers).json(), summary)
            self.assertEqual(client.get("/v1/audio/" + self.note, headers=self.headers).content, self.audio)
        for path in self.archive.rglob("*"):
            if path.is_file():
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                self.assertNotIn(self.audio, path.read_bytes())
                self.assertNotIn(self.key, path.read_bytes())
        self.assertEqual({p.suffix for p in (self.archive / "database").iterdir()}, {".sqlite3"})

    def test_audio_is_deduplicated_and_retained_until_last_referencing_snapshot_expires(self):
        first = self.snapshot(keep=2)
        second = self.snapshot(keep=2)
        self.assertEqual(first["audio"], second["audio"])
        self.assertEqual(len(list((self.archive / "audio" / "objects").iterdir())), 1)
        self.delete_note()
        third = self.snapshot(keep=2)
        self.assertFalse(third["audio"])
        self.assertEqual(len(list((self.archive / "audio" / "objects").iterdir())), 1)
        self.snapshot(keep=2)
        self.assertEqual(list((self.archive / "audio" / "objects").iterdir()), [])
        self.assertEqual(len(list((self.archive / "database").iterdir())), 2)

    def test_missing_live_audio_does_not_publish_or_prune_a_snapshot(self):
        saved = self.snapshot(keep=1)
        next((self.source / "audio").iterdir()).unlink()
        with self.assertRaises(FileNotFoundError):
            self.snapshot(keep=1)
        self.assertEqual([p.stem for p in (self.archive / "audio" / "snapshots").iterdir()], [saved["id"]])
        verify(self.archive, saved["id"], self.key)

    def test_audio_inventory_is_copied_under_a_live_database_writer_lock(self):
        original = backup.read_file
        blocked = []
        def read_while_writer_attempts(path):
            if path.parent == self.source / "audio":
                with sqlite3.connect(self.source / "sync.sqlite3", timeout=0) as db:
                    with self.assertRaises(sqlite3.OperationalError):
                        db.execute("BEGIN IMMEDIATE")
                    blocked.append(True)
            return original(path)
        with patch.object(backup, "read_file", side_effect=read_while_writer_attempts):
            saved = self.snapshot()
        self.assertEqual(blocked, [True])
        verify(self.archive, saved["id"], self.key)

    def test_corrupt_audio_and_wrong_key_cannot_restore_or_replace_existing_data(self):
        saved = self.snapshot()
        with self.assertRaises(InvalidToken):
            restore(self.archive, saved["id"], self.root / "wrong-key", Fernet.generate_key())
        self.assertFalse((self.root / "wrong-key").exists())
        with self.assertRaises(ValueError):
            restore(self.archive, saved["id"], self.source, self.key)
        obj = next((self.archive / "audio" / "objects").iterdir())
        obj.write_bytes(b"broken")
        with self.assertRaises(ValueError):
            restore(self.archive, saved["id"], self.root / "broken", self.key)
        with self.assertRaises(ValueError):
            self.snapshot()
        self.assertFalse((self.root / "broken").exists())
        self.assertEqual(self.client.get("/v1/audio/" + self.note, headers=self.headers).content, self.audio)

    def test_snapshot_inventory_rejects_path_traversal_and_symlinks(self):
        saved = self.snapshot()
        path = self.archive / "audio" / "snapshots" / (saved["id"] + ".json")
        invalid = dict(saved, audio={"../outside": "a" * 64})
        path.write_text(json.dumps(invalid))
        with self.assertRaises(ValueError):
            verify(self.archive, saved["id"], self.key)
        with self.assertRaises(ValueError):
            verify(self.archive, "../outside", self.key)
        path.write_text(json.dumps(saved))
        obj = next((self.archive / "audio" / "objects").iterdir())
        obj.unlink()
        obj.symlink_to(next((self.source / "audio").iterdir()))
        with self.assertRaises(OSError):
            verify(self.archive, saved["id"], self.key)

    def test_concurrent_backup_is_refused_and_invalid_retention_never_prunes(self):
        saved = self.snapshot()
        with archive_lock(self.archive):
            with self.assertRaises(BlockingIOError):
                self.snapshot()
        with self.assertRaises(ValueError):
            self.snapshot(keep=0)
        verify(self.archive, saved["id"], self.key)

    def test_corrupt_database_fails_integrity_before_restore(self):
        saved = self.snapshot()
        database = self.archive / "database" / (saved["id"] + ".sqlite3")
        with sqlite3.connect(database) as db:
            db.execute("DELETE FROM records")
        with self.assertRaises(ValueError):
            restore(self.archive, saved["id"], self.root / "tampered", self.key)
        self.assertFalse((self.root / "tampered").exists())


if __name__ == "__main__":
    unittest.main()
