"""Synthetic pinned-seam sources for the private Mac stagers.

Each source holds exactly the seams the stagers rewrite, so the stagers run
without the private upstream checkouts. Records are pinned to these bytes.
"""
import hashlib
import json
from pathlib import Path

HELPER = 'apple/macos-helper/'
MAIN = HELPER + 'Sources/AgentDeviceMacOSHelper/main.swift'
SNAPSHOT = HELPER + 'Sources/AgentDeviceMacOSHelper/SnapshotTraversal.swift'
GATE = HELPER + 'Sources/AgentDeviceMacOSHelper/MacHelperOwnershipGate.swift'
GATE_TESTS = HELPER + 'Tests/AgentDeviceMacOSHelperTests/MacHelperOwnershipGateTests.swift'

HELPER_SOURCES = {
    MAIN: '''import Foundation

func run(command: String, arguments: [String]) throws -> Encodable {
  if !(["snapshot", "press"].contains(command)) {
    throw HelperError.invalidArgs("unsupported command")
  }
    switch command {
    case "snapshot":
      return SuccessEnvelope(data: try captureSnapshotResponse(surface: surface, bundleId: bundleId))
    default:
      throw HelperError.invalidArgs("unsupported command")
    }
}
''',
    SNAPSHOT: '''import ApplicationServices

private struct SnapshotBuildResult {
  let nodes: [SnapshotNodeResponse]
  let truncated: Bool
}

struct SnapshotNodeResponse: Encodable {
  let label: String?
  let enabled: Bool?
}

private final class SnapshotBuildState {
  var nodes: [SnapshotNodeResponse] = []
  var truncated = false
  var visited: [AXUIElement] = []
}

func captureSnapshotResponse(surface: String, target: MacApplicationTarget?) throws -> SnapshotResponse {
  if let target {
    let result = buildSnapshot(surface: surface)
    return SnapshotResponse(surface: surface, nodes: result.nodes, truncated: result.truncated, applicationTarget: target)
  }
  let result = buildSnapshot(surface: surface)
  return SnapshotResponse(surface: surface, nodes: result.nodes, truncated: result.truncated)
}

private func buildSnapshot(surface: String) -> SnapshotBuildResult {
  let state = SnapshotBuildState()
  if surface == "menubar" {
    state.nodes.append(SnapshotNodeResponse(
      label: "Menu",
      enabled: true,
    ))
    return SnapshotBuildResult(nodes: state.nodes, truncated: state.truncated)
  }
  if surface == "desktop" { return SnapshotBuildResult(nodes: state.nodes, truncated: state.truncated) }
  if surface == "dock" { return SnapshotBuildResult(nodes: state.nodes, truncated: state.truncated) }
  guard let root = rootElement(surface) else { return SnapshotBuildResult(nodes: state.nodes, truncated: true) }
  if state.nodes.count > SnapshotTraversalLimits.maxNodes { return SnapshotBuildResult(nodes: state.nodes, truncated: true) }
  _ = appendNode(root, state: state, depth: 0, parentIndex: nil, context: SnapshotContext())
  return SnapshotBuildResult(nodes: state.nodes, truncated: state.truncated)
}

private func appendNode(
  _ element: AXUIElement,
  state: SnapshotBuildState,
  depth: Int,
  parentIndex: Int?,
  context: SnapshotContext,
  maxDepth: Int = SnapshotTraversalLimits.maxDepth
) -> Int? {
  if state.visited.contains(where: { CFEqual($0, element) }) {
    return parentIndex
  }
  state.visited.append(element)
  let role = stringAttribute(element, attribute: kAXRoleAttribute as String)
  let subrole = stringAttribute(element, attribute: kAXSubroleAttribute as String)
  let title = stringAttribute(element, attribute: kAXTitleAttribute as String)
  let description = stringAttribute(element, attribute: kAXDescriptionAttribute as String)
  let value = stringAttribute(element, attribute: kAXValueAttribute as String)
  let identifier = stringAttribute(element, attribute: "AXIdentifier")
  let windowTitle = context.windowTitle ?? inferWindowTitle(for: element)
  let enabled = boolAttribute(element, attribute: kAXEnabledAttribute as String)
  state.nodes.append(SnapshotNodeResponse(
      label: title ?? description ?? value ?? identifier ?? windowTitle ?? role ?? subrole,
      enabled: enabled,
  ))
  let index = state.nodes.count - 1
  guard depth < maxDepth, !state.truncated else {
    return index
  }

  for child in snapshotChildren(of: element, role: role) {
    _ = appendNode(
      child,
      state: state,
      depth: depth + 1,
      parentIndex: index,
      context: context,
      maxDepth: maxDepth
    )
  }
  return index
}
''',
    GATE: '''import Foundation

enum MacHelperOwnershipGate {
  static func readAcknowledgement(descriptor: Int32, deadline: Date) throws {
    var acknowledgement = Data()
    while !acknowledgement.contains(0x0A) {
      acknowledgement.append(try readByte(descriptor, deadline: deadline))
    }
  }
}
''',
    GATE_TESTS: '''import XCTest

final class MacHelperOwnershipGateTests: XCTestCase {
  func testOversizeAcknowledgementIsRejected() throws {
    var descriptors: [Int32] = [0, 0]
    XCTAssertEqual(pipe(&descriptors), 0)
    defer { close(descriptors[0]); close(descriptors[1]) }
  }
}
''',
}

# Every seam mac_sdk_session_patch.patch() edits, once per expected occurrence.
SESSION_SEAMS = {
    'src/daemon/session-state.ts': ['export type SessionState = {'],
    'src/core/dispatch-context.ts': ['    surface?: SessionSurface;'],
    'src/daemon/runtime-session.ts': ['      surface: session.surface,'],
    'packages/contracts/src/client-app.ts': ['    launchArgs?: string[];', 'export type AppOpenResult = {'],
    'packages/contracts/src/client-capture.ts': ['export type CaptureSnapshotResult = {'],
    'packages/contracts/src/command-flags.ts': ['  launchArgs?: string[];'],
    'packages/contracts/src/request-envelope.ts': ['    launchArgs?: string[];'],
    'src/commands/command-flags.ts': ['    launchArgs: options.launchArgs,'],
    'src/commands/management/app.ts': ["    app: stringField('App name, bundle id, package, or URL.'),"],
    'packages/contracts/src/application-lifecycle-runtime.ts': ['export type OpenApplicationInput = Readonly<{', 'export type OpenApplicationOutcome = Readonly<{'],
    'packages/platform-apple/src/lifecycle.ts': ['  const timing: MutableOpenTiming = {};'],
    'src/daemon/session-lifecycle/internal/session-open-prepare.ts': [
        'export async function validateResolvedOpenRequest(params: {', '  const { shouldRelaunch, openTarget, surface, device } = params;'],
    'src/daemon/session-lifecycle/internal/session-open.ts': [
        '  if (session) {\n    if (req.flags?.saveScript)', 'validateResolvedOpenRequest({\n', 'validateResolvedOpenRequest({\n'],
    'src/daemon/session-lifecycle/internal/session-open-execution.ts': [
        '  const outcome = await lifecycle.operations.openApplication({', '  const nextSession = buildNextOpenSession({',
        '    launchConfirmation: outcome.launchConfirmation,'],
    'src/daemon/session-lifecycle/internal/session-open-surface.ts': [
        '  appBundleId?: string;', '  appBundleId?: string;', '  if (appBundleId) result.appBundleId = appBundleId;',
        '      snapshot: undefined,', '    actions: [],'],
    'src/daemon/request-execution-scope.ts': [
        '  const existingSession = existingRef?.session;', '          surface: sessionStore.get(scope.sessionName)?.surface,'],
    'src/daemon/request-generic-dispatch.ts': ['    surface: session.surface,'],
    'src/daemon/snapshot-runtime-capture-input.ts': [
        '  const { appBundleId, trace, surface } = session ?? {};', '      appBundleId,',
        '    execution: runtimeExecutionFromContext(context),', '    requestId?: string;', '    requestId: context.requestId,'],
    'src/daemon/interaction/internal/interaction-touch-prepare.ts': [
        '      params.contextFromFlags(params.req.flags, session.appBundleId, session.trace?.outPath),'],
    'src/daemon/snapshot-capture.ts': [
        '      appBundleId: context.appBundleId,', '      appBundleId: context.appBundleId,', 'type SnapshotData = {',
        'type CaptureSnapshotResult = {', '  const deferred = await resolveDeferredInteractionOutcome({', '    snapshot: latest.snapshot,'],
    'packages/contracts/src/snapshot-types.ts': ['export type BackendSnapshotResult = {'],
    'src/commands/capture/runtime/snapshot.ts': [
        'export type SnapshotCommandResult = {', '  return copySnapshotClickabilityEvidence(capture.snapshot, {\n    nodes: capture.snapshot.nodes,'],
    'src/daemon/snapshot-command-runtime.ts': ['        snapshot: capture.snapshot,'],
    'src/daemon/snapshot-runtime.ts': ['      const fallbackScreenshot = await captureSparseFallbackScreenshot({'],
    'src/agent-device-client.ts': ['          appId,\n          selection:', "    | 'androidSnapshot'", '    ...(keyboard ? { keyboard } : {}),'],
    'src/commands/output/result-serialization.ts': ['    nodes: result.nodes,'],
    'src/daemon/response-views.ts': ['  const carriedFields = ['],
}

SDK_SOURCES = {
    'packages/contracts/package.json': json.dumps({'name': '@agent-device/contracts', 'type': 'module',
        'exports': {'.': {'types': './src/index.ts', 'default': './src/index.ts'}}}, indent=2) + '\n',
    'packages/contracts/src/interactor-types.ts': '''import type { AppStateRuntimeResult } from './app-state.ts';

export type RunnerContext = {
  appBundleId?: string;
};

export type SnapshotOptions = BaseSnapshotOptions & {
  surface?: SessionSurface;
};

export type SnapshotResult = Omit<BackendSnapshotResult, 'backend' | 'nodes'> & {
  nodes: SnapshotNode[];
};
''',
    'packages/platform-apple/src/os/macos/helper.ts': '''import { createHash } from 'node:crypto';

function appendMacOsHelperContextArgs(
  args: string[],
  options: { bundleId?: string; surface?: SessionSurface },
): void {
  if (options.bundleId) {
    args.push('--bundle-id', assertMacOsBundleId(options.bundleId));
  }
}

export async function runMacOsSnapshotAction(
  surface: SessionSurface,
  options: { bundleId?: string; signal?: AbortSignal } = {},
): Promise<{
  surface: SessionSurface;
  nodes: MacOsSnapshotNode[];
  truncated: boolean;
  backend: 'macos-helper';
}> {
  const args = ['snapshot', '--surface', surface];
  appendMacOsHelperContextArgs(args, options);
  return await runMacOsHelper(args, { signal: options.signal });
}

export async function runMacOsReadTextAction(): Promise<string> {
  return '';
}

export async function runMacOsPressAction(
  x: number,
  y: number,
  options: {
    bundleId?: string;
    surface?: SessionSurface;
    holdMs?: number;
    signal?: AbortSignal;
  } = {},
): Promise<{
  x: number;
  y: number;
  holdMs?: number;
}> {
  const args = ['press', '--x', String(x), '--y', String(y)];
  appendMacOsHelperContextArgs(args, options);
  return await runMacOsHelper(args, {
    signal: options.signal,
  });
}

export async function runMacOsScreenshotAction(): Promise<void> {}
''',
    'packages/platform-apple/src/os/macos/surface-snapshot.ts': '''export async function captureSurface(surface: SessionSurface, options: SnapshotOptions) {
  return await runMacOsSnapshotAction(surface, {
    bundleId: surface === 'menubar' ? options.appBundleId : undefined,
  });
}
''',
    'packages/platform-apple/src/interactions.ts': '''export async function press(context: RunnerContext, x: number, y: number, surface: SessionSurface, options: PressOptions) {
  const posted = await runMacOsPressAction(x, y, {
    bundleId: context.appBundleId,
    surface,
    holdMs: options.holdMs,
  });
  return posted.holdMs === undefined ? {} : { holdMs: posted.holdMs };
}
''',
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def session_source(seams):
    return '// Synthetic pinned seams.\n' + '\n'.join(seams) + '\n'


def write_tree(root, files):
    for relative, text in files.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(text.encode() if isinstance(text, str) else text)
    return {relative: sha((root / relative).read_bytes()) for relative in files}


def write_session_tree(root, overrides=None):
    files = {name: session_source(seams) for name, seams in SESSION_SEAMS.items()}
    files.update(overrides or {})
    return write_tree(root, files)


def write_record(path, record):
    path.write_text(json.dumps(record, sort_keys=True, indent=2) + '\n')
    return sha(path.read_bytes())
