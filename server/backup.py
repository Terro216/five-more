"""Local-only snapshots: SQLite and deduplicated encrypted audio in separate trees.

No network transport or key storage. A manifest is published only after validation.
"""
import argparse
import fcntl
import hashlib
import json
import os
import re
import sqlite3
import tempfile
import uuid
from contextlib import closing, contextmanager
from datetime import datetime, timezone
from pathlib import Path

from cryptography.fernet import Fernet


def sha(data):
    return hashlib.sha256(data).hexdigest()


def private_directory(path):
    if path.is_symlink():
        raise ValueError("Symlink directory refused")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not path.is_dir():
        raise ValueError("Not a directory")
    path.chmod(0o700)
    return path


def read_file(path):
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as stream:
        return stream.read()


def write_file(path, data):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def readonly(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError("Missing database")
    return sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=15)


@contextmanager
def archive_lock(root):
    private_directory(root)
    descriptor = os.open(root / ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(descriptor)


def snapshot_id(value):
    if not re.fullmatch(r"\d{8}T\d{12}Z-[0-9a-f]{32}", value):
        raise ValueError("Invalid snapshot ID")
    return value


def manifest_for(root, identifier):
    identifier = snapshot_id(identifier)
    manifest = json.loads(read_file(root / "audio" / "snapshots" / (identifier + ".json")))
    if manifest.get("version") != 1 or manifest.get("id") != identifier:
        raise ValueError("Invalid snapshot manifest")
    for name, digest in manifest["audio"].items():
        if not re.fullmatch(r"[a-f0-9]{64}", name) or not re.fullmatch(r"[a-f0-9]{64}", digest):
            raise ValueError("Invalid audio object")
    return manifest


def validate_database(path, key):
    cipher = Fernet(key)
    with closing(readonly(path)) as db:
        if db.execute("PRAGMA integrity_check").fetchall() != [("ok",)] or db.execute("PRAGMA foreign_key_check").fetchall():
            raise ValueError("Database integrity failed")
        check = db.execute("SELECT value FROM service_metadata WHERE key='encryption_check'").fetchone()
        if check is None or cipher.decrypt(check[0]) != b"five_more_v1":
            raise ValueError("Incorrect storage key")
        for (payload,) in db.execute("SELECT data FROM records"):
            json.loads(cipher.decrypt(payload))
        return db.execute("SELECT file,bytes,sha FROM audio ORDER BY file").fetchall()


def validate_audio(data, size, digest, key):
    plain = Fernet(key).decrypt(data)
    if len(plain) != size or sha(plain) != digest:
        raise ValueError("Audio integrity failed")


def _verify(root, identifier, key):
    manifest = manifest_for(root, identifier)
    database = root / "database" / (identifier + ".sqlite3")
    if sha(read_file(database)) != manifest["databaseSha256"]:
        raise ValueError("Database checksum failed")
    rows = validate_database(database, key)
    if {r[0] for r in rows} != set(manifest["audio"]):
        raise ValueError("Audio inventory mismatch")
    for name, size, digest in rows:
        object_sha = manifest["audio"][name]
        data = read_file(root / "audio" / "objects" / object_sha)
        if sha(data) != object_sha:
            raise ValueError("Audio checksum failed")
        validate_audio(data, size, digest, key)
    return manifest


def verify(root, identifier, key):
    root = Path(root).absolute()
    with archive_lock(root):
        return _verify(root, identifier, key)


def create_snapshot(source, root, key, keep=14):
    source, root = Path(source).resolve(), Path(root).resolve()
    if keep < 1 or keep > 365 or source == root or source in root.parents or root in source.parents:
        raise ValueError("Separate source and archive directories required")
    if not (source / "sync.sqlite3").is_file() or (source / "sync.sqlite3").is_symlink():
        raise ValueError("Missing source database")
    identifier = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ-") + uuid.uuid4().hex
    with archive_lock(root):
        database = private_directory(root / "database")
        audio = private_directory(root / "audio")
        objects = private_directory(audio / "objects")
        manifests = private_directory(audio / "snapshots")
        with tempfile.TemporaryDirectory(prefix=".pending-", dir=root) as temporary:
            staging = Path(temporary)
            copy = staging / "sync.sqlite3"
            write_file(copy, b"")
            # A distinct reader can use SQLite backup while this connection prevents
            # upload/delete transactions from changing the file inventory.
            with closing(sqlite3.connect(source / "sync.sqlite3", timeout=15)) as lock:
                lock.execute("BEGIN IMMEDIATE")
                try:
                    with closing(readonly(source / "sync.sqlite3")) as reader, closing(sqlite3.connect(copy)) as output:
                        reader.backup(output)
                        output.execute("PRAGMA journal_mode=DELETE")
                    rows = validate_database(copy, key)
                    inventory = {}
                    for name, size, digest in rows:
                        if not re.fullmatch(r"[a-f0-9]{64}", name):
                            raise ValueError("Invalid live audio filename")
                        encrypted = read_file(source / "audio" / name)
                        validate_audio(encrypted, size, digest, key)
                        object_sha = sha(encrypted)
                        target = objects / object_sha
                        if target.exists():
                            if sha(read_file(target)) != object_sha:
                                raise ValueError("Existing backup object is corrupt")
                        else:
                            pending = staging / object_sha
                            write_file(pending, encrypted)
                            pending.rename(target)
                        inventory[name] = object_sha
                finally:
                    lock.rollback()
            # Flush objects and standalone database before publishing the commit marker.
            sync_directory(objects)
            with copy.open("rb") as stream:
                os.fsync(stream.fileno())
            manifest = {"version": 1, "id": identifier, "databaseSha256": sha(read_file(copy)), "audio": inventory}
            pending_manifest = staging / "manifest.json"
            write_file(pending_manifest, json.dumps(manifest, sort_keys=True).encode())
            copy.rename(database / (identifier + ".sqlite3"))
            sync_directory(database)
            pending_manifest.rename(manifests / (identifier + ".json"))
            sync_directory(manifests)
        # Validate every manifest before pruning; never infer references from filenames.
        saved = sorted(manifests.glob("*.json"), reverse=True)
        all_manifests = [(path, manifest_for(root, path.stem)) for path in saved]
        retained = all_manifests[:keep]
        referenced = {obj for _, item in retained for obj in item["audio"].values()}
        for path, item in all_manifests[keep:]:
            path.unlink()
            (database / (item["id"] + ".sqlite3")).unlink(missing_ok=True)
        sync_directory(manifests)
        sync_directory(database)
        for path in objects.iterdir():
            if re.fullmatch(r"[a-f0-9]{64}", path.name) and path.name not in referenced:
                path.unlink()
        sync_directory(manifests)
        return manifest


def restore(root, identifier, destination, key):
    """Validate first, then populate a new directory. Existing destinations are refused."""
    root, destination = Path(root).resolve(), Path(destination).absolute()
    if destination.exists() or destination.is_symlink() or root in destination.parents:
        raise ValueError("Restore requires a new destination outside the archive")
    with archive_lock(root):
        manifest = _verify(root, identifier, key)
        with tempfile.TemporaryDirectory(prefix=".restore-", dir=destination.parent) as temporary:
            staging = Path(temporary)
            write_file(staging / "sync.sqlite3", read_file(root / "database" / (identifier + ".sqlite3")))
            audio = private_directory(staging / "audio")
            for name, object_sha in manifest["audio"].items():
                write_file(audio / name, read_file(root / "audio" / "objects" / object_sha))
            sync_directory(audio)
            sync_directory(staging)
            # mkdir is an exclusive reservation, so a racing destination is never replaced.
            destination.mkdir(mode=0o700)
            (staging / "sync.sqlite3").rename(destination / "sync.sqlite3")
            audio.rename(destination / "audio")
            sync_directory(destination)
            sync_directory(destination.parent)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["create", "verify", "restore"])
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--key-file", type=Path, required=True)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--snapshot")
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--keep", type=int, default=14)
    args = parser.parse_args()
    key = read_file(args.key_file).strip()
    if args.action == "create":
        if args.source is None:
            parser.error("create requires --source")
        result = create_snapshot(args.source, args.archive, key, args.keep)
    elif args.action == "verify":
        if not args.snapshot:
            parser.error("verify requires --snapshot")
        result = verify(args.archive, args.snapshot, key)
    else:
        if not args.snapshot or args.destination is None:
            parser.error("restore requires --snapshot and --destination")
        result = restore(args.archive, args.snapshot, args.destination, key)
    print(json.dumps({"ok": True, "snapshot": result["id"], "audioFiles": len(result["audio"])}))


if __name__ == "__main__":
    main()
