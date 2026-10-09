#!/usr/bin/env python3
"""Explicit source-attributed compatibility patch; refuse every unknown SDK artifact."""
import argparse
import hashlib
import json
import os
import tempfile
from pathlib import Path

ORIGINAL_DIGEST = '7482d986259e9357bfbf5c2f6cada1f1231d5aa1e8cfbdec695dcd84ca37e9f7'
ORIGINAL = 'async function Ue(e,t){let n=async()=>{if(!We(e))try{await Ge(e.device)}finally{E(e.lease)}};if(t.leaseLockHeld){await n();return}try{await y(e.deviceId,n)}catch(t){c({level:`warn`,phase:`ios_runner_disposal_lease_lock_unavailable`,data:{deviceId:e.deviceId,sessionId:e.sessionId,error:t instanceof Error?t.message:String(t)}})}}'
REPLACEMENT = 'async function Ue(e,t){let n=async()=>{if(e.device.kind===`simulator`){let receipt=await intentsDisposeOwnedSimulatorRunner({device:e.device,lease:e.lease,sessionId:e.sessionId,hostPID:e.child?.pid,ownerPID:h,ownerStartTime:_(),ownerStateDir:S(),currentLease:()=>b(e.deviceId),configuredBundles:de},args=>ee(ie(e.device,args),{allowFailure:!0,timeoutMs:z}),text=>o(`plutil`,[`-convert`,`json`,`-o`,`-`,`-`],{allowFailure:!0,stdin:text,timeoutMs:z}));c({level:`info`,phase:`intents_owned_runner_release`,data:receipt});E(e.lease)}else if(!We(e))try{await Ge(e.device)}finally{E(e.lease)}};if(t.leaseLockHeld){await n();return}await y(e.deviceId,n)}'
IMPORT = 'import{disposeOwnedSimulatorRunner as intentsDisposeOwnedSimulatorRunner}from"./intents-owned-runner-disposal.mjs";'
CLOSE_DIGEST = '0ff11ad4e3ec223d55f3557883ab68c3249341b1f0e6fbe2870c6786867bb6c7'
CLOSE_ORIGINAL = 'retainRunner:p'
CLOSE_REPLACEMENT = 'retainRunner:n.device.kind===`simulator`?!1:p'
CLIENT_DIGEST = 'e857c629409998d5412820e64ba859f2204bc56f574184425214a21bcdfdd7af'
CLIENT_ORIGINAL = 'r&&at(r)&&(await Wt(r,n),j.get(e)===r&&j.delete(e))'
CLIENT_REPLACEMENT = 'r&&(at(r)||r.device.kind===`simulator`&&r.state===`draining`)&&(await Wt(r,n),j.get(e)===r&&j.delete(e))'

def candidate(file, expected_digest, original, replacement, prefix=''):
    data = file.read_bytes(); text = data.decode()
    if hashlib.sha256(data).hexdigest() == expected_digest:
        if text.count(original) != 1: raise ValueError('SDK patch seam changed')
        return (prefix + text.replace(original, replacement)).encode()
    if text.count(replacement) != 1 or (prefix and text.count(prefix) != 1): raise ValueError('Unknown SDK source digest')
    restored = text.removeprefix(prefix).replace(replacement, original).encode()
    if hashlib.sha256(restored).hexdigest() != expected_digest: raise ValueError('Altered SDK source')
    return data

def patch(package: Path):
    for directory in [package, package / 'dist', package / 'dist/src']:
        if directory.is_symlink() or not directory.is_dir(): raise ValueError('Invalid SDK directory')
    manifest = package / 'package.json'
    if manifest.is_symlink() or not manifest.is_file() or json.loads(manifest.read_text())['version'] != '0.21.20':
        raise ValueError('Unqualified SDK package')
    source = package / 'dist/src/runner-disposal.js'
    if source.is_symlink() or not source.is_file(): raise ValueError('Invalid SDK source')
    helper_source = Path(__file__).resolve().parents[1] / 'patches/ownedRunnerDisposal.mjs'
    helper = helper_source.read_bytes()
    destination = source.parent / 'intents-owned-runner-disposal.mjs'
    receipt_path = package / 'intents-lifecycle-patch.json'
    close = source.parent / 'session2.js'
    client = source.parent / 'runner-client.js'
    for file in [source, close, client, destination, receipt_path]:
        if file.is_symlink() or (file.exists() and (not file.is_file() or file.stat().st_nlink != 1)):
            raise ValueError('Invalid SDK patch file')
    patched = candidate(source, ORIGINAL_DIGEST, ORIGINAL, REPLACEMENT, IMPORT)
    close_patched = candidate(close, CLOSE_DIGEST, CLOSE_ORIGINAL, CLOSE_REPLACEMENT)
    client_patched = candidate(client, CLIENT_DIGEST, CLIENT_ORIGINAL, CLIENT_REPLACEMENT)
    receipt = {'schemaVersion': 1, 'package': 'agent-device', 'version': '0.21.20',
        'patchVersion': 'intents-owned-disposal-3', 'originalSHA256': ORIGINAL_DIGEST,
        'patchedSHA256': hashlib.sha256(patched).hexdigest(), 'helperSHA256': hashlib.sha256(helper).hexdigest(),
        'closeOriginalSHA256': CLOSE_DIGEST, 'closePatchedSHA256': hashlib.sha256(close_patched).hexdigest(),
        'clientOriginalSHA256': CLIENT_DIGEST, 'clientPatchedSHA256': hashlib.sha256(client_patched).hexdigest(),
        'license': 'MIT', 'source': 'Published agent-device 0.21.20 dist/src/runner-disposal.js; existing owner-lock disposal seam'}
    expected = json.loads((Path(__file__).resolve().parents[1] / 'dependencies.lock.json').read_text())['packages']['agent-device']['lifecyclePatch']
    if (expected['id'] != receipt['patchVersion'] or expected['originalSourceSHA256'] != receipt['originalSHA256']
        or expected['patchedSourceSHA256'] != receipt['patchedSHA256'] or expected['helperSHA256'] != receipt['helperSHA256']
        or expected['closeOriginalSourceSHA256'] != receipt['closeOriginalSHA256'] or expected['closePatchedSourceSHA256'] != receipt['closePatchedSHA256']
        or expected['clientOriginalSourceSHA256'] != receipt['clientOriginalSHA256'] or expected['clientPatchedSourceSHA256'] != receipt['clientPatchedSHA256']):
        raise ValueError('SDK lifecycle patch differs from the reviewed lock')
    for file, content in [(destination, helper), (source, patched), (close, close_patched), (client, client_patched), (receipt_path, (json.dumps(receipt, indent=2) + '\n').encode())]:
        with tempfile.NamedTemporaryFile(dir=file.parent, prefix='.intents-patch-', delete=False) as temporary:
            temporary.write(content); temporary.flush(); os.fsync(temporary.fileno())
            temporary_path = Path(temporary.name)
        try:
            temporary_path.chmod(0o644); temporary_path.replace(file)
        finally: temporary_path.unlink(missing_ok=True)
    print(json.dumps(receipt))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--package', type=Path, required=True)
    args = parser.parse_args(); patch(args.package)
