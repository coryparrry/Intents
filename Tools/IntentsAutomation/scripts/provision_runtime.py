#!/usr/bin/env python3
"""Build-time only: download the exact reviewed runtime; never used by the app."""
import hashlib, json, tarfile, urllib.request
from pathlib import Path
root=Path(__file__).resolve().parents[1]
lock=json.loads((root/'dependencies.lock.json').read_text())['node']
cache=root/'.runtime';cache.mkdir(exist_ok=True)
archive=cache/lock['archive']
if not archive.exists():
    with urllib.request.urlopen(lock['url'],timeout=60) as response: archive.write_bytes(response.read(100*1024*1024))
if hashlib.sha256(archive.read_bytes()).hexdigest()!=lock['sha256']: raise SystemExit('Node archive integrity mismatch')
with tarfile.open(archive) as package: package.extractall(cache,filter='data')
print(cache / lock['archive'].removesuffix('.tar.gz') / 'bin' / 'node')
