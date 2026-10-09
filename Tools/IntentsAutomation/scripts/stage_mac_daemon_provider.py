#!/usr/bin/env python3
"""Reconstruct a separate private SDK source with a gated helper and daemon provider API.

Only immutable archive bytes and the reviewed extension are copied. No daemon is started.
"""
import argparse
import io
import json
from pathlib import Path, PurePosixPath
import tarfile

import verify_private_mac_source as baseline
import stage_mac_helper_startup_gate as gate
import patch_owned_mac_daemon as owned_daemon

LOCK_SHA256 = '4692c0805fa264f5cbc6de20b19b6c9f2bd6f4575a759be8ba86b3b075e3dbd5'
TEMPLATES = Path(__file__).resolve().parents[1] / 'patches/mac-ownership'
RECEIPT = 'intents-native-daemon-provider.json'
RUNTIME = 'src/daemon/server/daemon-runtime.ts'
ENTRY = 'src/sdk/intents-daemon.ts'
LIFECYCLE = 'packages/platform-apple/src/lifecycle.ts'
OWNERSHIP_TEST = 'src/intents-mac-sdk-ownership.test.ts'
LIFECYCLE_TEST = 'src/intents-mac-lifecycle.test.ts'
OPEN_PREPARE = 'src/daemon/session-lifecycle/internal/session-open-prepare.ts'
OPTIONS = 'export type DaemonRuntimeOptions = {\n'
PROVIDERS = '    providers: {\n      appleRunnerProvider: providerRuntimeProviders.appleRunnerProvider,'
BUILD_ENTRY = "    index: 'src/sdk/index.ts',"


def relative(name):
    path = PurePosixPath(name)
    if not name or path.is_absolute() or '..' in path.parts or path.as_posix() != name or len(path.parts) > 32 or '\0' in name:
        raise ValueError('Invalid source relative path')
    return name


def replace_once(data, old, new):
    text = data.decode('utf-8')
    if text.count(old) != 1:
        raise ValueError('Pinned daemon composition seam differs')
    return text.replace(old, new, 1).encode('utf-8')


def expected_inputs(source, archive, checkpoint):
    # This also validates the pinned archive/checkpoint and all baseline native inputs.
    native, native_receipt = gate.expected_inputs(source, archive, checkpoint)
    archive_bytes = baseline.read(archive, 64 * 1024 * 1024)
    checkpoint_bytes = baseline.read(checkpoint, 1024 * 1024)
    if baseline.digest(archive_bytes) != baseline.ARCHIVE_SHA256 or baseline.digest(checkpoint_bytes) != baseline.CHECKPOINT_SHA256:
        raise ValueError('Pinned SDK origin differs')
    record = json.loads(checkpoint_bytes)
    if len(record['sdkPatchedSourceSHA256']) != 36 or len(record['nativePatchedSourceSHA256']) != 9:
        raise ValueError('Reviewed SDK extension map differs')
    inputs = {}
    total = 0
    with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode='r:gz') as bundle:
        prefix = 'callstack-agent-device-' + baseline.REVISION[:7] + '/'
        for index, member in enumerate(bundle.getmembers(), 1):
            if index > 10000 or not member.name.startswith(prefix):
                if member.isdir() and member.name == prefix.rstrip('/'):
                    continue
                raise ValueError('Archive source root or count differs')
            name = relative(member.name[len(prefix):].rstrip('/'))
            if member.isdir():
                continue
            total += member.size
            if not member.isfile() or member.size > 8 * 1024 * 1024 or total > 128 * 1024 * 1024 or name in inputs:
                raise ValueError('Archive source type/size differs')
            inputs[name] = bundle.extractfile(member).read()
    for name, expected in {**record['sdkPatchedSourceSHA256'], **record['nativePatchedSourceSHA256']}.items():
        relative(name)
        data = baseline.read(source / name, 8 * 1024 * 1024)
        if baseline.digest(data) != expected:
            raise ValueError('Reviewed SDK source bytes differ: ' + name)
        inputs[name] = data
    # Install all seventeen recomputed native inputs, including the startup gate.
    if {name for name in inputs if baseline.native_input(name)} != set(native) - set(gate.ADDITIONS.values()):
        raise ValueError('Baseline native source set differs')
    inputs.update(native)
    lock_bytes = baseline.read(TEMPLATES / 'native-daemon-provider-lock.json', 65536)
    if baseline.digest(lock_bytes) != LOCK_SHA256:
        raise ValueError('Pinned daemon provider lock differs')
    lock = json.loads(lock_bytes)
    boundary = {key: lock.get(key) for key in ('schemaVersion', 'artifactVariant', 'customerRuntimeEnabled', 'hardwareQualified', 'helperABI')}
    if boundary != {'schemaVersion': 1, 'artifactVariant': 'private-owned-mac-daemon-provider-source',
                    'customerRuntimeEnabled': False, 'hardwareQualified': False, 'helperABI': 'startup-gate-v1'}:
        raise ValueError('Private SDK boundary differs')
    entry = baseline.read(TEMPLATES / 'intents-daemon.ts', 65536)
    lifecycle_test = baseline.read(TEMPLATES / 'intents-mac-lifecycle.test.ts', 65536)
    patch_bytes = baseline.read(Path(owned_daemon.__file__).resolve(), 65536)
    if lock['templates'] != {'intents-daemon.ts': baseline.digest(entry),
                             'intents-mac-lifecycle.test.ts': baseline.digest(lifecycle_test),
                             'patch_owned_mac_daemon.py': baseline.digest(patch_bytes)} or ENTRY in inputs or LIFECYCLE_TEST in inputs:
        raise ValueError('Pinned daemon entry differs')
    inputs[LIFECYCLE] = replace_once(inputs[LIFECYCLE], "binding.device.platform !== 'macos'",
                                    "(binding.device.platform !== 'apple' || binding.device.appleOs !== 'macos')")
    inputs[LIFECYCLE] = replace_once(inputs[LIFECYCLE], 'input.macBundlePath, input.execution.signal)',
                                    'input.macBundlePath, binding.signal)')
    inputs[OWNERSHIP_TEST] = replace_once(inputs[OWNERSHIP_TEST], "{platform:'macos',id:'mac'",
                                         "{platform:'apple',appleOs:'macos',id:'mac'")
    inputs[OPEN_PREPARE] = replace_once(inputs[OPEN_PREPARE], "device.platform !== 'macos'",
                                       "(device.platform !== 'apple' || device.appleOs !== 'macos')")
    inputs[OPEN_PREPARE] = owned_daemon.apply_open_prepare(inputs[OPEN_PREPARE])
    inputs['src/daemon/session-lifecycle/internal/session-open.ts'] = owned_daemon.apply_session_open(inputs['src/daemon/session-lifecycle/internal/session-open.ts'])
    inputs['src/daemon/session-selector.ts'] = replace_once(inputs['src/daemon/session-selector.ts'],
        "if (flags.udid && (!isIosFamily(device) || flags.udid !== device.id)) {",
        "if (flags.udid && ((!isIosFamily(device) && !(device.platform === 'apple' && device.appleOs === 'macos' && session.applicationTarget)) || flags.udid !== device.id)) {")
    inputs['src/backend.ts'] = replace_once(inputs['src/backend.ts'], 'export type BackendSnapshotResult = {',
        "export type BackendSnapshotResult = {\n  applicationTarget?: import('@agent-device/contracts/mac-application-target').MacApplicationTarget;")
    ownership = replace_once(inputs[OWNERSHIP_TEST], "import {test} from 'vitest';",
        "import {test} from 'vitest';\nimport {macOsHelperSurface} from '@agent-device/contracts/session';\nconst helperSurface=macOsHelperSurface('frontmost-app')!;")
    ownership = replace_once(ownership, "captureMacOsSurfaceSnapshot({surface:'frontmost-app'", 'captureMacOsSurfaceSnapshot({surface:helperSurface')
    ownership = replace_once(ownership, "runMacOsSnapshotAction('frontmost-app'", 'runMacOsSnapshotAction(helperSurface')
    # The reviewed test has four press helper calls; keep response/session surfaces unbranded.
    if ownership.count(b"{surface:'frontmost-app',bundleId:") != 4:
        raise ValueError('Pinned helper surface test seams differ')
    ownership = ownership.replace(b"{surface:'frontmost-app',bundleId:", b'{surface:helperSurface,bundleId:')
    ownership = replace_once(ownership, "{surface:'desktop',bundleId:", "{surface:macOsHelperSurface('desktop')!,bundleId:")
    ownership = replace_once(ownership, "sessionScope:'workspace'", "sessionScope:{kind:'named-local'}")
    inputs[OWNERSHIP_TEST] = replace_once(ownership, "RESPONSE_VIEWS.snapshot(serialized,'digest')",
        "RESPONSE_VIEWS.snapshot!(serialized,'digest')")
    inputs[LIFECYCLE_TEST] = lifecycle_test
    inputs['intents-mac-vitest.config.ts'] = replace_once(inputs['intents-mac-vitest.config.ts'],
        "include:['src/intents-mac-sdk-ownership.test.ts',",
        "include:['src/intents-mac-sdk-ownership.test.ts','src/intents-mac-lifecycle.test.ts',")
    runtime = replace_once(inputs[RUNTIME], OPTIONS,
                           OPTIONS + "  appleToolProvider?: import('../../platform-runtime/request-providers.ts').PlatformProviderResolvers['appleToolProvider'];\n")
    inputs[RUNTIME] = replace_once(runtime, PROVIDERS,
                                  '    providers: {\n      ...(options.appleToolProvider ? { appleToolProvider: options.appleToolProvider } : {}),\n      appleRunnerProvider: providerRuntimeProviders.appleRunnerProvider,')
    inputs[RUNTIME] = owned_daemon.apply(inputs[RUNTIME])
    inputs['src/daemon/server/http-server.ts'] = owned_daemon.apply_http(inputs['src/daemon/server/http-server.ts'])
    inputs['tsdown.config.ts'] = replace_once(inputs['tsdown.config.ts'], BUILD_ENTRY,
                                             BUILD_ENTRY + "\n    'intents-daemon': 'src/sdk/intents-daemon.ts',")
    package = json.loads(inputs['package.json'])
    if './intents-daemon' in package['exports']:
        raise ValueError('Unexpected daemon public entry')
    package['exports']['./intents-daemon'] = {'types': './dist/src/intents-daemon.d.ts', 'import': './dist/src/intents-daemon.js'}
    package['private'] = True
    inputs['package.json'] = (json.dumps(package, indent=2) + '\n').encode('utf-8')
    inputs[ENTRY] = entry
    receipt = dict(boundary, baselineRevision=baseline.REVISION, officialArchiveSHA256=baseline.ARCHIVE_SHA256,
                   extensionCheckpointSHA256=baseline.CHECKPOINT_SHA256, daemonProviderLockSHA256=LOCK_SHA256,
                   startupGateLockSHA256=native_receipt['startupGateLockSHA256'], signed=False,
                   daemonStarted=False, helperInvoked=False, uiInteracted=False,
                   sourceInputsSHA256={name: baseline.digest(data) for name, data in sorted(inputs.items())})
    return inputs, receipt


def receipt_bytes(receipt):
    return (json.dumps(receipt, indent=2, sort_keys=True) + '\n').encode('utf-8')


def verify(candidate, source, archive, checkpoint):
    inputs, receipt = expected_inputs(source, archive, checkpoint)
    if not candidate.is_absolute() or candidate.resolve(strict=True) != candidate or not candidate.is_dir():
        raise ValueError('Require a canonical SDK candidate')
    actual = set()
    for count, path in enumerate(candidate.rglob('*'), 1):
        if count > 12000 or len(path.relative_to(candidate).parts) > 32 or path.is_symlink() or path.resolve(strict=True) != path:
            raise ValueError('SDK candidate traversal or alias differs')
        if path.is_file():
            actual.add(path.relative_to(candidate).as_posix())
        elif not path.is_dir():
            raise ValueError('SDK candidate contains nonregular input')
    if actual != set(inputs) | {RECEIPT}:
        raise ValueError('SDK candidate input set differs')
    for name, data in inputs.items():
        if baseline.read(candidate / name, 8 * 1024 * 1024) != data:
            raise ValueError('SDK candidate source bytes differ: ' + name)
    if baseline.read(candidate / RECEIPT, 1024 * 1024) != receipt_bytes(receipt):
        raise ValueError('SDK candidate receipt differs')
    return receipt


def stage(candidate, source, archive, checkpoint):
    inputs, receipt = expected_inputs(source, archive, checkpoint)
    if not candidate.is_absolute() or candidate.parent.resolve(strict=True) != candidate.parent:
        raise ValueError('Require a canonical SDK destination parent')
    candidate.mkdir()
    for name, data in inputs.items():
        path = candidate / name
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('xb') as stream:
            stream.write(data)
    with (candidate / RECEIPT).open('xb') as stream:
        stream.write(receipt_bytes(receipt))
    return verify(candidate, source, archive, checkpoint)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['candidate', 'source', 'archive', 'checkpoint']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    record = (verify if args.verify_only else stage)(args.candidate, args.source, args.archive, args.checkpoint)
    print('Verified disabled SDK/daemon source inputs:', len(record['sourceInputsSHA256']))


if __name__ == '__main__':
    main()
