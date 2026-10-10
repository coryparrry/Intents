"""Private Mac-only daemon composition. Default upstream runtime semantics are preserved."""

OPTIONS = "  appleToolProvider?: import('../../platform-runtime/request-providers.ts').PlatformProviderResolvers['appleToolProvider'];\n"
OWNED_OPTIONS = OPTIONS + """  intentsOwnedMac?: {
    deviceId: string;
    inventory: import('@agent-device/contracts/device').ProviderDeviceInventorySource;
    admitRequest: (request: Parameters<import('../daemon-request.ts').DaemonInvokeFn>[0]) => boolean;
  };
"""
STARTUP_BEGIN = '    await platformDaemonLifecycleOwners.configureForDaemonLock({'
STARTUP_END = '    const opened = await openDaemonServers();'
CLAIMS_BEGIN = '    await reconcileDeviceClaimsForDaemonStartup('
CLAIMS_END = '    // Arms the initial idle-reap timer:'
TEARDOWN = '  const teardownDaemonSession = async (session: SessionState): Promise<void> => {\n'
OWNED_TEARDOWN = TEARDOWN + """    if (options.intentsOwnedMac) {
      if (session.device.id !== options.intentsOwnedMac.deviceId || session.device.platform !== 'apple' ||
          session.device.appleOs !== 'macos' || session.appLog || session.audioProbe || session.perfCapture || session.screenRecording || session.trace || session.lease) {
        throw new AppError('COMMAND_FAILED', 'Unexpected resources in owned Mac daemon');
      }
      const previouslyReleased = shutdownClaimLedger.claims.released.length;
      await shutdownClaimLedger.releaseClaim(session);
      shutdownClaimLedger.finalize(session);
      if (session.deviceClaim && !shutdownClaimLedger.claims.released.slice(previouslyReleased).some(record =>
          record.session === session.name && record.deviceId === options.intentsOwnedMac!.deviceId)) {
        throw new AppError('COMMAND_FAILED', 'Owned Mac device claim release unverified');
      }
      sessionStore.delete(session.name);
      return;
    }
"""
REQUEST = '  const handleRequest: DaemonInvokeFn = async (req) => {\n'
OWNED_REQUEST = '  let shuttingDown = false, ownedAdmissionClosed = false;\n' + REQUEST + """    if (options.intentsOwnedMac) {
      const supplied = Buffer.from(req.token ?? '');
      const expected = Buffer.from(token);
      if (shuttingDown || ownedAdmissionClosed || supplied.length !== expected.length || !crypto.timingSafeEqual(supplied, expected) ||
          !['open', 'snapshot', 'press'].includes(req.command) || !options.intentsOwnedMac.admitRequest(req)) {
        return { ok: false, error: { code: 'UNAUTHORIZED', message: 'Private Mac request denied' } };
      }
    }
"""
SHUTDOWN = '    if (shuttingDown) return;\n'
OWNED_SHUTDOWN = """    if (options.intentsOwnedMac && inFlightRequestCount !== 0) {
      throw new AppError('COMMAND_FAILED', 'Owned Mac requests have not drained');
    }
""" + SHUTDOWN
REPLACEMENTS = [
    ("  shutdown: (options?: { exitCode?: number; cause?: unknown }) => Promise<void>;",
     "  drainOwnedRequests?: (timeoutMs: number) => Promise<boolean>;\n  shutdown: (options?: { exitCode?: number; cause?: unknown }) => Promise<void>;"),
    ('  return {\n    httpPort,\n    shutdown,', """  return {
    ...(options.intentsOwnedMac ? { drainOwnedRequests: async (timeoutMs: number) => {
      if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 5000) throw new AppError('INVALID_ARGS', 'Invalid owned request drain bound');
      ownedAdmissionClosed = true;
      const deadline = Date.now() + timeoutMs;
      while (inFlightRequestCount !== 0 && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 10));
      return inFlightRequestCount === 0;
    } } : {}),
    httpPort,
    shutdown,"""),
    (OPTIONS, OWNED_OPTIONS),
    ('    providerRuntimeProviders.deviceInventorySource,',
     '    options.intentsOwnedMac?.inventory ?? providerRuntimeProviders.deviceInventorySource,'),
    ('      const httpServer = await createDaemonHttpServer({\n        handleRequest,',
     '      const httpServer = await createDaemonHttpServer({\n        intentsRPCOnly: Boolean(options.intentsOwnedMac),\n        handleRequest,'),
    ('  const providerComposition = await createDefaultProviderRuntimeComposition(env);',
     '  const providerComposition = options.intentsOwnedMac ? { runtimes: [], platformModules: [] } : await createDefaultProviderRuntimeComposition(env);'),
    ('  void expiredProviderLeaseReleaser.retryPending();',
     '  if (!options.intentsOwnedMac) void expiredProviderLeaseReleaser.retryPending();'),
    ('    idleExpiryMs: resolveSessionIdleExpiryMs(env),',
     '    idleExpiryMs: options.intentsOwnedMac ? 0 : resolveSessionIdleExpiryMs(env),'),
    ('    env,\n  });\n\n  const handleRequest:',
     "    env: options.intentsOwnedMac ? { ...env, AGENT_DEVICE_DAEMON_IDLE_TIMEOUT_MS: '0' } : env,\n  });\n\n  const handleRequest:"),
    (TEARDOWN, OWNED_TEARDOWN),
    (REQUEST, OWNED_REQUEST),
    ('  prewarmPngWorker();', '  if (!options.intentsOwnedMac) prewarmPngWorker();'),
    (SHUTDOWN, OWNED_SHUTDOWN),
    ('  let shuttingDown = false;\n  const shutdown =', '  const shutdown ='),
    ('    await closeDaemonServers(servers);',
     "    await closeDaemonServers(servers);\n    if (options.intentsOwnedMac && inFlightRequestCount !== 0) throw new AppError('COMMAND_FAILED', 'Owned Mac requests have not drained');"),
    ('          await applicationLifecycle.detachForDaemonShutdown();',
     '          if (!options.intentsOwnedMac) await applicationLifecycle.detachForDaemonShutdown();'),
    ('      await platformDaemonLifecycleOwners.resetAndroidSnapshotHelper();',
     '      if (!options.intentsOwnedMac) await platformDaemonLifecycleOwners.resetAndroidSnapshotHelper();'),
    ('    await deviceRuntimeGateway.shutdown();',
     '    if (!options.intentsOwnedMac) await deviceRuntimeGateway.shutdown();'),
    ('    await applicationLifecycle.finalizeDaemonShutdown();',
     '    if (!options.intentsOwnedMac) await applicationLifecycle.finalizeDaemonShutdown();'),
    ('    await platformDaemonLifecycleOwners.clearDaemonLockConfiguration();',
     '    if (!options.intentsOwnedMac) await platformDaemonLifecycleOwners.clearDaemonLockConfiguration();'),
]


def apply(data):
    text = data.decode('utf-8')
    for old, new in REPLACEMENTS:
        # clearDaemonLockConfiguration appears in both startup failure and shutdown.
        expected = 2 if 'clearDaemonLockConfiguration' in old else 1
        if text.count(old) != expected:
            raise ValueError('Owned Mac daemon seam differs: ' + old.strip())
        text = text.replace(old, new)
    for begin, end in [(STARTUP_BEGIN, STARTUP_END), (CLAIMS_BEGIN, CLAIMS_END)]:
        if text.count(begin) != 1 or text.count(end) != 1 or text.index(begin) >= text.index(end):
            raise ValueError('Owned Mac daemon recovery block differs')
        start, stop = text.index(begin), text.index(end)
        text = text[:start] + '    if (!options.intentsOwnedMac) {\n' + text[start:stop] + '    }\n' + text[stop:]
    return text.encode('utf-8')


HTTP_OPTIONS = 'export async function createDaemonHttpServer(options: {\n'
HTTP_HANDLER = '  return http.createServer((req, res) => {\n'


def apply_http(data):
    text = data.decode('utf-8')
    for old, new in [(HTTP_OPTIONS, HTTP_OPTIONS + '  intentsRPCOnly?: boolean;\n'),
                     (HTTP_HANDLER, HTTP_HANDLER + """    if (options.intentsRPCOnly && (req.method !== 'POST' || req.url !== '/rpc')) {
      res.statusCode = 403;
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify({ error: 'Private Mac route denied' }));
      return;
    }
""")]:
        if text.count(old) != 1:
            raise ValueError('Owned Mac HTTP seam differs')
        text = text.replace(old, new, 1)
    return text.encode('utf-8')


def apply_open_prepare(data):
    text = data.decode('utf-8')
    replacements = [
        ("import { isDeepLinkTarget } from '@agent-device/contracts/command';",
         "import { isDeepLinkTarget } from '@agent-device/contracts/command';\nimport {parseMacApplicationSelection} from '@agent-device/contracts/mac-application-target';"),
        ('  existingSurface?: SessionSurface,\n): SessionSurface | DaemonResponse {',
         '  existingSurface?: SessionSurface,\n  macBundlePath?: string,\n): SessionSurface | DaemonResponse {'),
        ('  } = params;\n  await runtime.operations.prepareApplicationOpen({', '''  } = params;
  if (req.flags?.macBundlePath !== undefined) {
    if (surface !== 'frontmost-app' || runtimeHintPlan.applyRuntimeHints || runtimeHintPlan.clearRemovedRuntimeHints) {
      return {type: 'response', response: invalidOpenArgs('Exact Mac selection does not accept ambient preparation or runtime hints')};
    }
    const selection = parseMacApplicationSelection({bundleId: openTarget, canonicalBundlePath: req.flags.macBundlePath});
    return {type: 'details', details: {appBundleId: selection.bundleId, runtime: runtimeHintPlan.runtime}};
  }
  await runtime.operations.prepareApplicationOpen({'''),
        ('    return resolveRequestedOpenSurface({', """    if (macBundlePath !== undefined) {
      if (device.platform !== 'apple' || device.appleOs !== 'macos' || surfaceFlag !== 'frontmost-app') {
        throw new AppError('INVALID_ARGS', 'Exact Mac selection requires frontmost-app on Mac');
      }
      parseMacApplicationSelection({bundleId: openTarget, canonicalBundlePath: macBundlePath});
      return 'frontmost-app';
    }
    return resolveRequestedOpenSurface({"""),
    ]
    for old, new in replacements:
        if text.count(old) != 1:
            raise ValueError('Owned Mac surface seam differs')
        text = text.replace(old, new, 1)
    return text.encode('utf-8')


def apply_session_open(data):
    text = data.decode('utf-8')
    for old, new in [('      session.surface,\n    );', '      session.surface,\n      req.flags?.macBundlePath,\n    );'),
                     ('resolveOpenSurfaceResponse(device, req.flags?.surface, openTarget);',
                      'resolveOpenSurfaceResponse(device, req.flags?.surface, openTarget, undefined, req.flags?.macBundlePath);')]:
        if text.count(old) != 1:
            raise ValueError('Owned Mac session surface seam differs')
        text = text.replace(old, new, 1)
    return text.encode('utf-8')
