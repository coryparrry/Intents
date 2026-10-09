import Foundation

struct AutomationSecretProgramCallback: Sendable {
    let handle: AutomationRPC.ReverseHandler
    func callAsFunction(_ method: String, _ input: AutomationJSON) async throws -> AutomationJSON { try await handle(method, input) }
}

/// Native-owned capability. It is never decoded from a request or capsule.
struct AutomationSecretProgramTransport: Sendable {
    let run: @Sendable (AutomationJSON, ContinuousClock.Instant, AutomationSecretProgramCallback) async throws -> AutomationJSON
    let closeAndDrain: @Sendable () async -> Bool
}

#if os(macOS)
/// One secret-only Node child and its native callbacks under the existing UI lease.
/// The caller's retained executor revokes native bindings before joining this owner.
actor AutomationMacSecretProgramTransport {
    static func owned(unitRoot: URL, state: URL, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease,
                      leases: AutomationDeviceLeaseManager) async throws -> AutomationMacSecretProgramTransport {
        guard lease.target.kind == .nativeMac, lease.target.loginSession != nil, await leases.isDurable,
              await leases.isCurrent(lease) else { throw AutomationSecretFillSession.Failure.denied }
        let unit = try AutomationPrivateMacDaemonUnit.load(root: unitRoot)
        guard let entry = unit.secretProgramEntry else { throw AutomationSecretFillSession.Failure.denied }
        return try .init(configuration: .init(node: unit.node, entry: entry, stateDirectory: state, retainDiagnostics: false),
            scope: scope, lease: lease, leases: leases, revalidate: {
                let current = try AutomationPrivateMacDaemonUnit.load(root: unitRoot)
                guard current.evidence == unit.evidence, current.secretProgramEntry == entry else { throw AutomationSecretFillSession.Failure.denied }
            })
    }
    private let configuration: AutomationSidecarProcess.Configuration
    private let scope: AutomationScope
    private let lease: AutomationDeviceLeaseManager.Lease
    private let leases: AutomationDeviceLeaseManager
    private let revalidate: @Sendable () async throws -> Void
    private let beforeStart: @Sendable () async -> Void
    private nonisolated let revocation = AutomationNativeTaskRevocation<AutomationJSON>()
    private var process: AutomationSidecarProcess?
    private var execution: Task<AutomationJSON, Error>?
    private var identity: AutomationProcessIdentity?
    private var handler: AutomationRPC.ReverseHandler?
    private var deadline: ContinuousClock.Instant?
    private var callbacks: [UUID: Task<AutomationJSON, Error>] = [:]
    private var used = false, closed = false, dispatching = false
    private var closingTask: Task<Bool, Never>?

    // Internal synthetic fixture seam; shipping construction uses owned() below.
    init(configuration: AutomationSidecarProcess.Configuration, scope: AutomationScope,
         lease: AutomationDeviceLeaseManager.Lease, leases: AutomationDeviceLeaseManager,
         revalidate: @escaping @Sendable () async throws -> Void, beforeStart: @escaping @Sendable () async -> Void = {}) throws {
        try scope.validate()
        guard configuration.helper == nil, !configuration.privateMacDaemon, !configuration.retainDiagnostics,
              scope.runId == lease.runID, scope.leaseGeneration == lease.generation, lease.control == .ui,
              !FileManager.default.fileExists(atPath: configuration.stateDirectory.path) else { throw AutomationSecretFillSession.Failure.denied }
        self.configuration = configuration; self.scope = scope; self.lease = lease; self.leases = leases; self.revalidate = revalidate
        self.beforeStart = beforeStart
    }
    func capability() -> AutomationSecretProgramTransport {
        .init(run: { payload, deadline, handler in try await self.run(payload, deadline: deadline, handler: handler) },
              closeAndDrain: { await self.closeAndDrain() })
    }
    func run(_ payload: AutomationJSON, deadline: ContinuousClock.Instant, handler: AutomationSecretProgramCallback) async throws -> AutomationJSON {
        guard !used, !closed, !revocation.isRevoked, payload.object?["scope"] == (try json(scope)) else { throw AutomationSecretFillSession.Failure.denied }
        used = true; self.handler = handler.handle; self.deadline = deadline
        let task = Task { try await self.execute(payload, deadline: deadline) }
        execution = task
        guard revocation.install(task) else { task.cancel(); _ = await task.result; throw AutomationSecretFillSession.Failure.denied }
        let watchdog = Task {
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            task.cancel(); _ = await self.closeAndDrain()
        }
        defer { watchdog.cancel(); self.handler = nil; self.deadline = nil; execution = nil; revocation.retire() }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: {
                task.cancel(); Task { _ = await self.closeAndDrain() }
            }
            try await requireOpen(deadline); return result
        } catch { throw AutomationSecretFillSession.Failure.outcomeUnresolved }
    }
    private func execute(_ payload: AutomationJSON, deadline: ContinuousClock.Instant) async throws -> AutomationJSON {
        try await requireOpen(deadline); try await revalidate(); try await requireOpen(deadline)
        let child = try AutomationSidecarProcess(configuration: configuration, reverse: { method, input in try await self.reverse(method, input) })
        process = child
        await beforeStart(); try await requireOpen(deadline)
        try await child.start()
        guard let identity = await child.processIdentity else { throw AutomationSecretFillSession.Failure.outcomeUnresolved }
        self.identity = identity
        try await leases.recordRunner(.init(scope: scope, process: identity, role: .sidecar, executablePath: configuration.node.path), lease: lease)
        try await requireOpen(deadline)
        let hello = try await child.rpc.request(.hello, params: .object(["protocolVersion": .number(1), "scope": try json(scope)]),
                                                timeout: ContinuousClock.now.duration(to: deadline))
        guard hello == .object(["protocolVersion": .number(1), "artifactVariant": .string("private-opaque-secret-program"),
                               "customerRuntimeEnabled": .bool(false), "hardwareQualified": .bool(false)]) else { throw AutomationSecretFillSession.Failure.denied }
        try await requireOpen(deadline)
        guard let operationID = payload.object?["operationId"]?.string, let digest = payload.object?["payloadDigest"]?.string else { throw AutomationSecretFillSession.Failure.denied }
        try await leases.recordDispatch(.init(scope: scope, operationID: operationID, payloadDigest: digest), lease: lease)
        try await requireOpen(deadline)
        dispatching = true; defer { dispatching = false }
        return try await child.rpc.request(.secretRunProgram, params: payload, timeout: ContinuousClock.now.duration(to: deadline))
    }
    private func reverse(_ method: String, _ input: AutomationJSON) async throws -> AutomationJSON {
        guard dispatching, method == "secret.fillBinding", let handler, let deadline, callbacks.count < 30 else { throw AutomationSecretFillSession.Failure.denied }
        try await requireOpen(deadline)
        let id = UUID(), task = Task {
            try await AutomationNativeSecretDeadline.$value.withValue(deadline) { try await handler(method, input) }
        }
        callbacks[id] = task; defer { callbacks.removeValue(forKey: id) }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try await requireOpen(deadline); return result
    }
    nonisolated func closeAndDrain() async -> Bool {
        revocation.revoke(); return await closeOnActor()
    }
    private func closeOnActor() async -> Bool {
        closed = true; dispatching = false; handler = nil; deadline = nil
        callbacks.values.forEach { $0.cancel() }
        if let closingTask { return await closingTask.value }
        let execution = self.execution; execution?.cancel()
        let task = Task {
            // A queued start must finish or be refused before the final child snapshot.
            if let execution { _ = await execution.result }
            let pending = Array(self.callbacks.values), child = self.process
            var reaped = true
            if let child {
                _ = try? await child.rpc.request(.cancel, params: .object([:]), timeout: .seconds(1))
                reaped = await child.stop()
                if let identity = await child.processIdentity {
                    switch identity.presence() { case .absent, .replaced: break; case .matching, .unknown: reaped = false }
                } else if await child.processID != 0 { reaped = false }
            }
            for callback in pending { _ = await callback.result }
            return reaped
        }
        closingTask = task; return await task.value
    }
    private func requireOpen(_ deadline: ContinuousClock.Instant) async throws {
        guard !closed, !revocation.isRevoked, !Task.isCancelled, ContinuousClock.now < deadline,
              await leases.isCurrent(lease) else { throw AutomationSecretFillSession.Failure.denied }
        guard !closed, !revocation.isRevoked, !Task.isCancelled, ContinuousClock.now < deadline else { throw AutomationSecretFillSession.Failure.denied }
    }
    private func json<T: Encodable>(_ value: T) throws -> AutomationJSON { try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(value)) }
}
#endif
