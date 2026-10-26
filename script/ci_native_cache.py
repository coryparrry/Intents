#!/usr/bin/env python3
"""Preserve unchanged checkout mtimes so cached Swift builds can be incremental."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tempfile

MANIFEST = "ci-source-metadata.json"
SECOND = 1_000_000_000
MAX_TIME = 4_102_444_800 * SECOND  # Reject invalid or unreasonably distant cached times.


def relative_path(name):
    """Validate a canonical relative POSIX source name, rejecting traversal, absolute paths, backslashes, and NUL bytes."""
    if not isinstance(name, str) or not name or "\\" in name or "\0" in name:
        raise ValueError("Invalid cached source path")
    path = PurePosixPath(name)
    if not path.parts or path.is_absolute() or ".." in path.parts or path.as_posix() != name:
        raise ValueError("Cached source path must be relative and canonical")
    return path


def tracked_files(root):
    """Yield Git-tracked regular files beneath root while excluding every path that traverses a symlink; propagate Git failures."""
    names = subprocess.run(["git", "ls-files", "-z"], cwd=root, check=True,
                           stdout=subprocess.PIPE).stdout.decode("utf-8").split("\0")
    for name in names:
        if not name:
            continue
        relative = relative_path(name)
        path = root
        for part in relative.parts:
            path = path / part
            if path.is_symlink():
                break
        else:
            if path.is_file():
                yield name, path


def digest(path):
    """Compute a file SHA-256 incrementally in one-megabyte blocks without loading the full file."""
    fingerprint = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            fingerprint.update(block)
    return fingerprint.hexdigest()


def read_manifest(path):
    """Read and validate bounded version-one source metadata, returning an empty mapping if absent and rejecting symlinks or invalid hashes and times."""
    if path.is_symlink():
        raise ValueError("Cached source manifest must not be a symlink")
    if not path.exists():
        return {}
    if path.stat().st_size > 64 * 1024 * 1024:
        raise ValueError("Cached source manifest is too large")
    data = json.loads(path.read_text())
    if (not isinstance(data, dict) or type(data.get("version")) is not int
            or data["version"] != 1 or not isinstance(data.get("files"), dict)):
        raise ValueError("Invalid cached source manifest")
    for name, entry in data["files"].items():
        relative_path(name)
        if (not isinstance(entry, dict) or set(entry) != {"sha256", "mtime_ns"}
                or not isinstance(entry["sha256"], str)
                or not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"])
                or type(entry["mtime_ns"]) is not int
                or not 0 <= entry["mtime_ns"] < MAX_TIME):
            raise ValueError("Invalid cached source metadata")
    return data["files"]


def restore(root, derived_data):
    """Restore cached mtimes only for unchanged tracked content and separate same-second edits; return restored and changed counts."""
    entries = read_manifest(derived_data / MANIFEST)
    restored = changed = 0
    if not entries:
        return restored, changed
    for name, path in tracked_files(root):
        previous = entries.get(name)
        if previous is None:
            continue
        current = path.stat()
        if digest(path) == previous["sha256"]:
            os.utime(path, ns=(current.st_atime_ns, previous["mtime_ns"]))
            restored += 1
        else:
            # Separate even same-second edits on build tools with coarse timestamp checks.
            if current.st_mtime_ns // SECOND == previous["mtime_ns"] // SECOND:
                os.utime(path, ns=(current.st_atime_ns, current.st_mtime_ns + SECOND))
            changed += 1
    return restored, changed


def capture(root, derived_data):
    """Hash tracked files, reject concurrent size or mtime changes, and atomically replace the cache manifest with captured metadata."""
    files = {}
    for name, path in tracked_files(root):
        before = path.stat()
        sha256 = digest(path)
        after = path.stat()
        if (before.st_mtime_ns, before.st_size) != (after.st_mtime_ns, after.st_size):
            raise ValueError("Source changed while capturing cache metadata")
        files[name] = {"sha256": sha256, "mtime_ns": after.st_mtime_ns}
    derived_data.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=derived_data, delete=False) as temporary:
        json.dump({"version": 1, "files": files}, temporary)
    os.replace(temporary.name, derived_data / MANIFEST)
    return len(files)


def main(argv=None):
    """Parse restore or capture paths, reject a symlinked cache directory, perform the selected metadata operation, and print its counts."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("restore", "capture"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--derived-data", type=Path, required=True)
    args = parser.parse_args(argv)
    if args.derived_data.is_symlink():
        raise ValueError("DerivedData cache must not be a symlink")
    root, derived_data = args.root.resolve(), args.derived_data.absolute()
    if args.operation == "capture":
        print(f"Captured source metadata for {capture(root, derived_data)} tracked files")
    else:
        restored, changed = restore(root, derived_data)
        print(f"Restored {restored} unchanged source mtimes; {changed} changed files require rebuilding")


if __name__ == "__main__":
    main()
