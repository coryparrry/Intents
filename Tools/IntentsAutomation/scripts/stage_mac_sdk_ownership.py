#!/usr/bin/env python3
"""Stage a private owned-Mac SDK experiment. Does not install or enable the runtime."""
import argparse
import hashlib
import json
from pathlib import Path
from stage_mac_snapshot_ownership import stage as stage_native
import mac_sdk_session_patch as session_patch

EXPECTED = {
    'packages/contracts/package.json': '386a903e26b760c7835f448cfd6b4b62bcbdee34e17dcbf6e5123ecb0540b5f4',
    'packages/contracts/src/interactor-types.ts': 'ac2b9cf7e2d130793a128ce33e10ece3dee9afc032750d116b6da47f5b5c8ad6',
    'packages/platform-apple/src/os/macos/helper.ts': '5446c165f2dd970c179d38354e1a83db94f41056b0f8442f19d109fb8a83c8f3',
    'packages/platform-apple/src/os/macos/surface-snapshot.ts': '2f2e548f7517ef2b4c15af44fffdaa859e5c5cdb80b1fa393ed693e4e3540b3a',
    'packages/platform-apple/src/interactions.ts': 'dd82b75ca87a01bf9b4510c02fad85406acc3cb524ad83caced0146d34364026',
}


def verify(root):
    for name, digest in EXPECTED.items():
        path = root / name
        if path.resolve(strict=True) != path or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError('Pinned SDK source differs: ' + name)


def replace(root, name, old, new, count=1):
    path = root / name
    text = path.read_text()
    if text.count(old) != count:
        raise ValueError('Pinned SDK patch shape differs: ' + name + ': ' + old[:80])
    path.write_text(text.replace(old, new))


def stage(source, output):
    verify(source)
    session_patch.verify(source)
    native = stage_native(source, output, application_ownership=True, recipient_input=True)
    verify(output)
    session_patch.verify(output)
    templates = Path(__file__).resolve().parents[1] / 'patches/mac-ownership'
    created = []
    for name in ['mac-application-target.ts', 'mac-owned-wire.ts']:
        path = output / 'packages/contracts/src' / name
        with path.open('xb') as stream:
            stream.write((templates / name).read_bytes())
        created.append(str(path.relative_to(output)))
    package_path = output / 'packages/contracts/package.json'
    package = json.loads(package_path.read_text())
    for name in ['mac-application-target', 'mac-owned-wire']:
        key = './' + name
        if key in package['exports']:
            raise ValueError('Unexpected existing Mac SDK export')
        package['exports'][key] = {'types': './src/' + name + '.ts', 'default': './src/' + name + '.ts'}
    package_path.write_text(json.dumps(package, indent=2) + '\n')
    types = 'packages/contracts/src/interactor-types.ts'
    replace(output, types, "import type { AppStateRuntimeResult }", "import type { MacApplicationTarget } from './mac-application-target.ts';\nimport type { AppStateRuntimeResult }")
    for marker in ['export type RunnerContext = {', 'export type SnapshotOptions = BaseSnapshotOptions & {',
                   "export type SnapshotResult = Omit<BackendSnapshotResult, 'backend' | 'nodes'> & {"]:
        replace(output, types, marker, marker + '\n  applicationTarget?: MacApplicationTarget;')
    helper = 'packages/platform-apple/src/os/macos/helper.ts'
    replace(output, helper, "import { createHash } from 'node:crypto';", """import { createHash } from 'node:crypto';
import {parseMacApplicationSelection, requireMacApplicationTargetEcho, macApplicationTargetArguments,
  type MacApplicationTarget} from '@agent-device/contracts/mac-application-target';
import {requireMacOpenEcho, requireMacPressEcho, validateMacOwnedPress} from '@agent-device/contracts/mac-owned-wire';""")
    replace(output, helper, 'options: { bundleId?: string; surface?: SessionSurface },',
            'options: { bundleId?: string; surface?: SessionSurface; applicationTarget?: MacApplicationTarget },')
    replace(output, helper, "  if (options.bundleId) {\n    args.push('--bundle-id', assertMacOsBundleId(options.bundleId));", """  if (options.applicationTarget) {
    args.push(...macApplicationTargetArguments(options.applicationTarget, options.bundleId, options.surface));
  }
  if (options.bundleId) {
    args.push('--bundle-id', assertMacOsBundleId(options.bundleId));""")
    snapshot_start = helper_text(output, helper, 'export async function runMacOsSnapshotAction(', 'export async function runMacOsReadTextAction(')
    snapshot_new = snapshot_start.replace('options: { bundleId?: string; signal?: AbortSignal } = {},',
        'options: { bundleId?: string; signal?: AbortSignal; applicationTarget?: MacApplicationTarget } = {},')
    snapshot_new = snapshot_new.replace("  backend: 'macos-helper';", "  backend: 'macos-helper';\n  applicationTarget?: MacApplicationTarget;")
    snapshot_new = snapshot_new.replace("  const args = ['snapshot', '--surface', surface];\n  appendMacOsHelperContextArgs(args, options);\n  return await runMacOsHelper(args, { signal: options.signal });", """  const args = ['snapshot'];
  appendMacOsHelperContextArgs(args, {...options, surface});
  const result = await runMacOsHelper<{
    surface: SessionSurface; nodes: MacOsSnapshotNode[]; truncated: boolean; backend: 'macos-helper';
    applicationTarget?: MacApplicationTarget;
  }>(args, { signal: options.signal });
  if (options.applicationTarget) requireMacApplicationTargetEcho(result.applicationTarget, options.applicationTarget);
  return result;""")
    if snapshot_new == snapshot_start:
        raise ValueError('Snapshot SDK patch empty')
    replace(output, helper, snapshot_start, snapshot_new)
    press_start = helper_text(output, helper, 'export async function runMacOsPressAction(', 'export async function runMacOsScreenshotAction(')
    press_new = press_start.replace('    bundleId?: string;', '    bundleId?: string;\n    applicationTarget?: MacApplicationTarget;', 1)
    press_new = press_new.replace('  x: number;\n  y: number;', "  applicationTarget?: MacApplicationTarget;\n  disposition?: 'submittedUnconfirmed';\n  releaseSubmitted?: boolean;\n  x: number;\n  y: number;", 1)
    press_new = press_new.replace("  const args = ['press',", "  if (options.applicationTarget) validateMacOwnedPress(x, y, options);\n  const args = ['press',", 1)
    press_new = press_new.replace('  return await runMacOsHelper(args, {', '  const invoke = options.applicationTarget ? runMacOsOwnedInputHelper : runMacOsHelper;\n  const result = await invoke<Record<string, unknown>>(args, {', 1)
    press_new = press_new.replace('  });\n}\n', """  });
  if (options.applicationTarget) {
    try { requireMacPressEcho(result, options.applicationTarget, {x, y}); }
    catch (error) { throw new AppError('COMMAND_FAILED', 'Mac input response could not be verified', {
      operationDisposition: 'uncertain', mayHaveCommitted: true, cause: String(error),
    }); }
  }
  return result as {x: number; y: number; applicationTarget?: MacApplicationTarget;
    disposition?: 'submittedUnconfirmed'; releaseSubmitted?: boolean; holdMs?: number};
}
""", 1)
    replace(output, helper, press_start, press_new)
    with (output / helper).open('a') as stream:
        stream.write("""
export async function runMacOsOwnedApplicationOpen(bundleId: string, canonicalBundlePath: string,
  signal?: AbortSignal): Promise<MacApplicationTarget> {
  const selection = parseMacApplicationSelection({bundleId, canonicalBundlePath});
  let result: Record<string, unknown>;
  try { result = await runMacOsHelper<Record<string, unknown>>([
    'app', 'open', '--bundle-id', selection.bundleId, '--bundle-path', selection.canonicalBundlePath,
  ], {signal}); }
  catch (error) { throw new AppError('COMMAND_FAILED', 'Owned Mac acquisition did not return verified identity', {
    ...(error instanceof AppError ? error.details : {}), acquisitionUncertain: true,
  }, error); }
  try { return requireMacOpenEcho(result, selection); }
  catch (error) { throw new AppError('COMMAND_FAILED', 'Mac open response could not be verified', {
    acquisitionUncertain: true, cause: String(error),
  }); }
}

async function runMacOsOwnedInputHelper<T extends Record<string, unknown>>(args: string[],
  options: {signal?: AbortSignal; timeoutMs?: number}): Promise<T> {
  try { return await runMacOsHelper<T>(args, options); }
  catch (error) { throw new AppError('COMMAND_FAILED', 'Owned Mac input submission did not return verified completion', {
    ...(error instanceof AppError ? error.details : {}), operationDisposition: 'uncertain', mayHaveCommitted: true,
  }, error); }
}
""")
    snapshot = 'packages/platform-apple/src/os/macos/surface-snapshot.ts'
    replace(output, snapshot, "bundleId: surface === 'menubar' ? options.appBundleId : undefined,", "bundleId: options.applicationTarget || surface === 'menubar' ? options.appBundleId : undefined,\n    applicationTarget: options.applicationTarget,")
    interactions = 'packages/platform-apple/src/interactions.ts'
    old = '    bundleId: context.appBundleId,\n    surface,\n    holdMs: options.holdMs,'
    replace(output, interactions, old, '    bundleId: context.appBundleId,\n    applicationTarget: context.applicationTarget,\n    surface,\n    holdMs: options.holdMs,')
    replace(output, interactions, '  return posted.holdMs === undefined ? {} : { holdMs: posted.holdMs };',
            '  if (context.applicationTarget) return {...posted};\n  return posted.holdMs === undefined ? {} : { holdMs: posted.holdMs };')
    session_patch.patch(output, replace)
    tests = output / 'src/intents-mac-sdk-ownership.test.ts'
    with tests.open('xb') as stream:
        stream.write((templates / tests.name).read_bytes())
    created.append(str(tests.relative_to(output)))
    config = output / 'intents-mac-vitest.config.ts'
    with config.open('xb') as stream:
        stream.write((templates / config.name).read_bytes())
    created.append(config.name)
    changed = sorted(set(EXPECTED) | set(created) | set(session_patch.BASELINE))
    record = {'runtimeEnabled': False, 'privateSourceExperiment': True, 'baselineRevision': native['baselineRevision'],
              'wholeSourceCommitVerifiedByStager': False, 'nativePatchRecord': 'intents-mac-snapshot-extension.json',
              'baselineSHA256': {**EXPECTED, **session_patch.BASELINE},
              'patchedSHA256': {name: hashlib.sha256((output / name).read_bytes()).hexdigest() for name in changed}}
    with (output / 'intents-mac-sdk-extension.json').open('x') as stream:
        json.dump(record, stream, indent=2)
    return record


def helper_text(root, name, start, end):
    text = (root / name).read_text()
    if text.count(start) != 1 or text.count(end) != 1 or text.index(end) <= text.index(start):
        raise ValueError('Pinned SDK function boundaries differ')
    return text[text.index(start):text.index(end)]


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, required=True)
    parser.add_argument('--output-root', type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(stage(args.source_root, args.output_root)))
    except (OSError, ValueError) as error:
        parser.exit(1, 'Mac SDK staging failed: ' + str(error) + '\n')
