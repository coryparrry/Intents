"""Pinned private SDK session integration; called only by the SDK source stager."""
import hashlib
import json
from pathlib import Path

BASELINE = json.loads((Path(__file__).resolve().parents[1] / 'patches/mac-ownership/sdk-session-baseline.json').read_text())


def verify(root):
    for name, digest in BASELINE.items():
        path = root / name
        if path.resolve(strict=True) != path or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError('Pinned SDK session source differs: ' + name)


def patch(root, replace):
    target_import = "import type { MacApplicationTarget } from '@agent-device/contracts/mac-application-target';\n"
    for name in ['src/daemon/session-state.ts', 'src/core/dispatch-context.ts']:
        path = root / name
        path.write_text(target_import + path.read_text())
    replace(root, 'src/daemon/session-state.ts', 'export type SessionState = {', 'export type SessionState = {\n  applicationTarget?: MacApplicationTarget;')
    replace(root, 'src/core/dispatch-context.ts', '    surface?: SessionSurface;', '    surface?: SessionSurface;\n    applicationTarget?: MacApplicationTarget;')
    replace(root, 'src/daemon/runtime-session.ts', '      surface: session.surface,', '      surface: session.surface,\n      applicationTarget: session.applicationTarget,')
    for name in ['packages/contracts/src/client-app.ts', 'packages/contracts/src/client-capture.ts', 'packages/contracts/src/application-lifecycle-runtime.ts']:
        path = root / name
        path.write_text("import type { MacApplicationTarget } from './mac-application-target.ts';\n" + path.read_text())
    replace(root, 'packages/contracts/src/client-app.ts', '    launchArgs?: string[];', '    launchArgs?: string[];\n    /** Explicit canonical installed .app path for the private exact-process Mac route. */\n    macBundlePath?: string;')
    replace(root, 'packages/contracts/src/client-app.ts', 'export type AppOpenResult = {', 'export type AppOpenResult = {\n  applicationTarget?: MacApplicationTarget;')
    replace(root, 'packages/contracts/src/client-capture.ts', 'export type CaptureSnapshotResult = {', 'export type CaptureSnapshotResult = {\n  applicationTarget?: MacApplicationTarget;')
    replace(root, 'packages/contracts/src/command-flags.ts', '  launchArgs?: string[];', '  launchArgs?: string[];\n  macBundlePath?: string;')
    replace(root, 'packages/contracts/src/request-envelope.ts', '    launchArgs?: string[];', '    launchArgs?: string[];\n    macBundlePath?: string;')
    replace(root, 'src/commands/command-flags.ts', '    launchArgs: options.launchArgs,', '    launchArgs: options.launchArgs,\n    macBundlePath: options.macBundlePath,')
    replace(root, 'src/commands/management/app.ts', "    app: stringField('App name, bundle id, package, or URL.'),", "    app: stringField('App name, bundle id, package, or URL.'),\n    macBundlePath: stringField('Exact installed Mac application path for the private owned route.'),")
    lifecycle_types = 'packages/contracts/src/application-lifecycle-runtime.ts'
    replace(root, lifecycle_types, 'export type OpenApplicationInput = Readonly<{', 'export type OpenApplicationInput = Readonly<{\n  macBundlePath?: string;')
    replace(root, lifecycle_types, 'export type OpenApplicationOutcome = Readonly<{', 'export type OpenApplicationOutcome = Readonly<{\n  applicationTarget?: MacApplicationTarget;')
    lifecycle = 'packages/platform-apple/src/lifecycle.ts'
    replace(root, lifecycle, '  const timing: MutableOpenTiming = {};', """  const timing: MutableOpenTiming = {};
  if (input.macBundlePath !== undefined) {
    if (binding.device.platform !== 'macos' || input.surface !== 'frontmost-app' || !input.target ||
      input.positionals.length !== 1 || input.positionals[0] !== input.target || input.relaunch ||
      input.runtimeLaunchUrl || Object.keys(input.runtimeHints).length > 0 ||
      input.execution.launchArgs?.length || input.execution.launchConsole || input.prewarmRunnerBeforeOpen) {
      throw new AppError('INVALID_ARGS', 'Owned Mac open requires one literal bundle ID, its path and app surface');
    }
    const {runMacOsOwnedApplicationOpen} = await import('./os/macos/helper.ts');
    const startedAt = Date.now();
    const applicationTarget = await runMacOsOwnedApplicationOpen(input.target, input.macBundlePath, input.execution.signal);
    return {applicationTarget, appBundleId: applicationTarget.bundleId,
      timing: {openDispatchDurationMs: Math.max(0, Date.now() - startedAt), runnerDemand: 'none'}};
  }""")
    prepare = 'src/daemon/session-lifecycle/internal/session-open-prepare.ts'
    replace(root, prepare, 'export async function validateResolvedOpenRequest(params: {', 'export async function validateResolvedOpenRequest(params: {\n  macBundlePath?: string;')
    replace(root, prepare, '  const { shouldRelaunch, openTarget, surface, device } = params;', """  const { shouldRelaunch, openTarget, surface, device } = params;
  if (params.macBundlePath !== undefined) {
    if (device.platform !== 'macos' || surface !== 'frontmost-app' || !openTarget || shouldRelaunch) {
      return invalidOpenArgs('Owned Mac selection requires a Mac app surface and literal bundle ID');
    }
    const {parseMacApplicationSelection} = await import('@agent-device/contracts/mac-application-target');
    try { parseMacApplicationSelection({bundleId: openTarget, canonicalBundlePath: params.macBundlePath}); }
    catch { return invalidOpenArgs('Invalid exact Mac application selection'); }
  }""")
    session_open = 'src/daemon/session-lifecycle/internal/session-open.ts'
    replace(root, session_open, '  if (session) {\n    if (req.flags?.saveScript)', """  if (session) {
    if (session.applicationTarget && (req.flags?.macBundlePath !== session.applicationTarget.canonicalBundlePath ||
      req.positionals?.[0] !== session.applicationTarget.bundleId)) {
      return invalidOpenArgs('Owned Mac reopen requires the same explicit bundle ID and application path');
    }
    if (req.flags?.saveScript)""")
    replace(root, session_open, 'validateResolvedOpenRequest({\n', 'validateResolvedOpenRequest({\n      macBundlePath: req.flags?.macBundlePath,\n', count=2)
    execution = 'src/daemon/session-lifecycle/internal/session-open-execution.ts'
    replace(root, execution, '  const outcome = await lifecycle.operations.openApplication({', '  const outcome = await lifecycle.operations.openApplication({\n    macBundlePath: req.flags?.macBundlePath,')
    replace(root, execution, '  const nextSession = buildNextOpenSession({', '  const nextSession = buildNextOpenSession({\n    applicationTarget: outcome.applicationTarget,')
    replace(root, execution, '    launchConfirmation: outcome.launchConfirmation,', '    launchConfirmation: outcome.launchConfirmation,\n    applicationTarget: outcome.applicationTarget,')
    surface = 'src/daemon/session-lifecycle/internal/session-open-surface.ts'
    path = root / surface
    path.write_text(target_import + path.read_text())
    replace(root, surface, '  appBundleId?: string;', '  appBundleId?: string;\n  applicationTarget?: MacApplicationTarget;', count=2)
    replace(root, surface, '  if (appBundleId) result.appBundleId = appBundleId;', '  if (appBundleId) result.appBundleId = appBundleId;\n  if (params.applicationTarget) result.applicationTarget = params.applicationTarget;')
    replace(root, surface, '      snapshot: undefined,', '      snapshot: undefined,\n      applicationTarget: params.applicationTarget,')
    replace(root, surface, '    actions: [],', '    actions: [],\n    applicationTarget: params.applicationTarget,')
    scope = 'src/daemon/request-execution-scope.ts'
    replace(root, scope, '  const existingSession = existingRef?.session;', """  const existingSession = existingRef?.session;
  if (existingSession?.applicationTarget && !['open', 'snapshot', 'press'].includes(lockedReq.command)) {
    return {type: 'response', response: {ok: false, error: {code: 'UNSUPPORTED_OPERATION',
      message: 'This private owned Mac route supports only exact open, snapshot and press'}}};
  }""")
    replace(root, scope, '          surface: sessionStore.get(scope.sessionName)?.surface,', '          surface: sessionStore.get(scope.sessionName)?.surface,\n          applicationTarget: sessionStore.get(scope.sessionName)?.applicationTarget,')
    replace(root, 'src/daemon/request-generic-dispatch.ts', '    surface: session.surface,', '    surface: session.surface,\n    applicationTarget: session.applicationTarget,')
    capture_input = 'src/daemon/snapshot-runtime-capture-input.ts'
    replace(root, capture_input, '  const { appBundleId, trace, surface } = session ?? {};', '  const { appBundleId, trace, surface, applicationTarget } = session ?? {};')
    replace(root, capture_input, '      appBundleId,', '      appBundleId,\n      applicationTarget,')
    replace(root, capture_input, '    execution: runtimeExecutionFromContext(context),', '    execution: {...runtimeExecutionFromContext(context), applicationTarget},')
    replace(root, capture_input, '    requestId?: string;', "    requestId?: string;\n    applicationTarget?: SnapshotRuntimeExecution['applicationTarget'];")
    replace(root, capture_input, '    requestId: context.requestId,', '    requestId: context.requestId,\n    applicationTarget: context.applicationTarget,')
    touch = 'src/daemon/interaction/internal/interaction-touch-prepare.ts'
    replace(root, touch, '      params.contextFromFlags(params.req.flags, session.appBundleId, session.trace?.outPath),', '      {...params.contextFromFlags(params.req.flags, session.appBundleId, session.trace?.outPath),\n        applicationTarget: session.applicationTarget},')
    capture = 'src/daemon/snapshot-capture.ts'
    replace(root, capture, '      appBundleId: context.appBundleId,', '      appBundleId: context.appBundleId,\n      applicationTarget: session?.applicationTarget,', count=2)
    path = root / capture
    path.write_text(target_import + path.read_text())
    replace(root, capture, 'type SnapshotData = {', 'type SnapshotData = {\n  applicationTarget?: MacApplicationTarget;')
    replace(root, capture, 'type CaptureSnapshotResult = {', 'type CaptureSnapshotResult = {\n  applicationTarget?: MacApplicationTarget;')
    replace(root, capture, '  const deferred = await resolveDeferredInteractionOutcome({', '  const deferred = params.session?.applicationTarget ? undefined : await resolveDeferredInteractionOutcome({')
    replace(root, capture, '    snapshot: latest.snapshot,', '    snapshot: latest.snapshot,\n    applicationTarget: latest.data.applicationTarget,')
    backend_types = 'packages/contracts/src/snapshot-types.ts'
    path = root / backend_types
    path.write_text("import type { MacApplicationTarget } from './mac-application-target.ts';\n" + path.read_text())
    replace(root, backend_types, 'export type BackendSnapshotResult = {', 'export type BackendSnapshotResult = {\n  applicationTarget?: MacApplicationTarget;')
    command = 'src/commands/capture/runtime/snapshot.ts'
    path = root / command
    path.write_text(target_import + path.read_text())
    replace(root, command, 'export type SnapshotCommandResult = {', 'export type SnapshotCommandResult = {\n  applicationTarget?: MacApplicationTarget;')
    replace(root, command, '  return copySnapshotClickabilityEvidence(capture.snapshot, {\n    nodes: capture.snapshot.nodes,', '  return copySnapshotClickabilityEvidence(capture.snapshot, {\n    nodes: capture.snapshot.nodes,\n    ...(capture.result.applicationTarget ? {applicationTarget: capture.result.applicationTarget} : {}),')
    replace(root, 'src/daemon/snapshot-command-runtime.ts', '        snapshot: capture.snapshot,', '        snapshot: capture.snapshot,\n        applicationTarget: capture.applicationTarget,')
    replace(root, 'src/daemon/snapshot-runtime.ts', '      const fallbackScreenshot = await captureSparseFallbackScreenshot({', '      const fallbackScreenshot = session?.applicationTarget ? undefined : await captureSparseFallbackScreenshot({')
    client = 'src/agent-device-client.ts'
    path = root / client
    path.write_text("import {parseMacApplicationTarget} from '@agent-device/contracts/mac-application-target';\n" + path.read_text())
    replace(root, client, '          appId,\n          selection:', '          appId,\n          ...(data.applicationTarget === undefined ? {} : {applicationTarget: parseMacApplicationTarget(data.applicationTarget)}),\n          selection:')
    replace(root, client, "    | 'androidSnapshot'", "    | 'applicationTarget'\n    | 'androidSnapshot'")
    replace(root, client, '    ...(keyboard ? { keyboard } : {}),', '    ...(data.applicationTarget === undefined ? {} : {applicationTarget: parseMacApplicationTarget(data.applicationTarget)}),\n    ...(keyboard ? { keyboard } : {}),')
    replace(root, 'src/commands/output/result-serialization.ts', '    nodes: result.nodes,', '    nodes: result.nodes,\n    ...(result.applicationTarget ? {applicationTarget: result.applicationTarget} : {}),')
    replace(root, 'src/daemon/response-views.ts', '  const carriedFields = [', "  const carriedFields = [\n    'applicationTarget',")
    return {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in BASELINE}
