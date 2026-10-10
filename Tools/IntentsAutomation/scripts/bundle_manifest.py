#!/usr/bin/env python3
"""Bounded private-runtime inventory; signatures remain a separate required check."""
import argparse
import hashlib
import json
import os
import stat
import subprocess
import tempfile
from pathlib import Path

MAX_ENTRIES = 10_000
MAX_DEPTH = 32
MAX_FILE_BYTES = 268_435_456
MAX_TOTAL_BYTES = 536_870_912
MAX_MANIFEST_BYTES = 4_194_304
REQUIRED = (
    'Helpers/IntentsAutomationNode', 'Helpers/agent-device-macos-helper',
    'Resources/Automation/dist/src/main.js', 'Resources/Automation/dependencies.lock.json',
    'Resources/Automation/node_modules/fsevents/fsevents.node',
    'Resources/Automation/node_modules/@esbuild/darwin-arm64/bin/esbuild',
)


def build_manifest(app):
    base = app.resolve(strict=True) / 'Contents'
    assets = base / 'Resources/Automation'
    if not assets.is_dir() or assets.resolve(strict=True) != assets:
        raise ValueError('Automation asset root must be a real directory')
    files = {}
    entries = 0
    total = 0

    def add(path, helper=False):
        nonlocal total
        resolved = path.resolve(strict=True)
        if helper:
            if resolved != path:
                raise ValueError('Executable helper aliases are forbidden')
        elif not resolved.is_relative_to(assets):
            raise ValueError('Dependency symlink escapes automation assets')
        fd = os.open(resolved, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as source:
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_FILE_BYTES:
                raise ValueError('Missing, nonregular or oversized runtime asset')
            digest = hashlib.sha256()
            consumed = 0
            while chunk := source.read(1_048_576):
                consumed += len(chunk)
                total += len(chunk)
                if consumed > MAX_FILE_BYTES or total > MAX_TOTAL_BYTES:
                    raise ValueError('Runtime bytes exceed inventory budget')
                digest.update(chunk)
        files[str(path.relative_to(base))] = digest.hexdigest()

    def walk(directory, depth):
        nonlocal entries
        if depth > MAX_DEPTH:
            raise ValueError('Runtime directory depth exceeds budget')
        with os.scandir(directory) as children:
            for child in children:
                entries += 1
                if entries > MAX_ENTRIES or depth + 1 > MAX_DEPTH:
                    raise ValueError('Runtime entry count exceeds budget')
                path = Path(child.path)
                if child.is_symlink() and path.is_dir():
                    raise ValueError('Directory symlinks are forbidden')
                if child.is_dir(follow_symlinks=False):
                    walk(path, depth + 1)
                elif path != assets / 'runtime-manifest.json':
                    add(path)

    for relative in REQUIRED[:2]:
        add(base / relative, helper=True)
    walk(assets, 0)
    if not set(REQUIRED).issubset(files):
        raise ValueError('Required runtime asset is missing')
    return {'schemaVersion': 1, 'architecture': 'arm64', 'nodeVersion': '24.21.0', 'files': dict(sorted(files.items()))}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()
    try:
        expected = build_manifest(args.app)
        base = args.app.resolve(strict=True) / 'Contents'
        manifest = base / 'Resources/Automation/runtime-manifest.json'
        if args.write:
            payload = (json.dumps(expected, indent=2) + '\n').encode()
            if len(payload) > MAX_MANIFEST_BYTES:
                raise ValueError('Runtime manifest exceeds budget')
            if manifest.exists() or manifest.is_symlink():
                info = manifest.lstat()
                if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                    raise ValueError('Manifest aliases and special files are forbidden')
            with tempfile.NamedTemporaryFile(dir=manifest.parent, prefix='.manifest-', delete=False) as output:
                temporary = Path(output.name)
                os.fchmod(output.fileno(), 0o644)
                output.write(payload)
                output.flush()
                os.fsync(output.fileno())
            try:
                temporary.replace(manifest)
            finally:
                temporary.unlink(missing_ok=True)
        else:
            if manifest.resolve(strict=True) != manifest:
                raise ValueError('Runtime manifest is aliased or oversized')
            descriptor = os.open(manifest, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(descriptor, 'rb') as source:
                info = os.fstat(source.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_MANIFEST_BYTES:
                    raise ValueError('Runtime manifest is nonregular or oversized')
                payload = source.read(MAX_MANIFEST_BYTES + 1)
            if len(payload) > MAX_MANIFEST_BYTES or json.loads(payload) != expected:
                raise ValueError('Runtime integrity mismatch')
            for relative in (REQUIRED[0], REQUIRED[1], REQUIRED[4], REQUIRED[5]):
                subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(base / relative)], check=True)
            subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '--deep', str(args.app)], check=True)
            print('Runtime hashes and nested signatures verified; notarisation and hardware gates are separate.')
    except (ValueError, OSError) as error:
        raise SystemExit(str(error)) from error


if __name__ == '__main__':
    main()
