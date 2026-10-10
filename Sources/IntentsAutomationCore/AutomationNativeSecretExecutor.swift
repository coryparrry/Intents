import Foundation

/// Runs the native-origin opaque operation table, locally or through an owned
/// secret-only transport. No SDK, controller, capture or literal-value interface.
actor AutomationNativeSecretExecutor {
    private let program: AutomationSecretFillProgram
    private let bindings: AutomationSecretFillBindings
    private let drainNativeOwner: @Sendable () async -> Void
    private let transport: AutomationSecretProgramTransport?
    private nonisolated let revocation = AutomationNativeTaskRevocation<AutomationJSON>()
    private var operation: Task<AutomationJSON, Error>?
    private var used = false, closed = false
    private var closingTask: Task<Void, Never>?
    private var ownerDrained = false
    init(program: AutomationSecretFillProgram, bindings: AutomationSecretFillBindings,
         drainNativeOwner: @escaping @Sendable () async -> Void, transport: AutomationSecretProgramTransport? = nil) {
        self.program = program; self.bindings = bindings; self.drainNativeOwner = drainNativeOwner
        self.transport = transport
    }
    func run() async throws -> AutomationJSON {
        guard !closed, !used, !revocation.isRevoked, operation == nil else { throw AutomationSecretFillSession.Failure.denied }
        used = true
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(program.timeoutMilliseconds))
        let task = Task {
            try await AutomationNativeSecretDeadline.$value.withValue(deadline) { try await self.executeAndFinish(deadline: deadline) }
        }; operation = task
        guard revocation.install(task) else {
            task.cancel(); _ = await task.result; operation = nil; throw AutomationSecretFillSession.Failure.denied
        }
        defer { operation = nil; revocation.retire() }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: {
                task.cancel(); Task { await self.closeAndDrain() }
            }
            try check(deadline)
            return result
        } catch { throw AutomationSecretFillSession.Failure.outcomeUnresolved }
    }
    nonisolated func closeAndDrain() async {
        revocation.revoke(); await closeOnActorAndDrain()
    }
    private func closeOnActorAndDrain() async {
        closed = true; let task = operation; task?.cancel()
        if let closingTask { await closingTask.value; return }
        let bindings = self.bindings, drain = drainNativeOwner
        let cleanup = Task {
            await bindings.revoke()
            if let task { _ = await task.result }
            else {
                _ = await self.transport?.closeAndDrain()
                await bindings.revokeAndDrain()
                if !self.ownerDrained { await drain(); self.ownerDrained = true }
            }
        }
        closingTask = cleanup; await cleanup.value; operation = nil
    }
    private func executeAndFinish(deadline: ContinuousClock.Instant) async throws -> AutomationJSON {
        let outcome: Result<AutomationJSON, Error>
        do { outcome = .success(try await execute(deadline: deadline)) }
        catch { outcome = .failure(AutomationSecretFillSession.Failure.outcomeUnresolved) }
        // Cleanup belongs to the retained task even if cancellation arrives after input.
        await bindings.revoke()
        let workerDrained = await transport?.closeAndDrain() ?? true
        await bindings.revokeAndDrain(); await drainNativeOwner(); ownerDrained = true
        try check(deadline)
        guard workerDrained else { throw AutomationSecretFillSession.Failure.outcomeUnresolved }
        return try outcome.get()
    }
    private func check(_ deadline: ContinuousClock.Instant) throws {
        guard !closed, !revocation.isRevoked, !Task.isCancelled, ContinuousClock.now < deadline else {
            throw AutomationSecretFillSession.Failure.outcomeUnresolved
        }
    }
    private func execute(deadline: ContinuousClock.Instant) async throws -> AutomationJSON {
        try check(deadline)
        guard await bindings.matchesProgram(program) else { throw AutomationSecretFillSession.Failure.denied }
        let payload = try await bindings.payload()
        try check(deadline)
        guard let references = payload.object?["bindings"]?.object else { throw AutomationSecretFillSession.Failure.denied }
        let scope = try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(program.scope))
        if let transport {
            let bindings = self.bindings
            let result = try await transport.run(payload, deadline, .init(handle: { method, input in
                try await AutomationNativeSecretDeadline.$value.withValue(deadline) {
                    try AutomationNativeSecretDeadline.check()
                    return try await bindings.handle(method: method, input: input)
                }
            }))
            try check(deadline)
            let completed = try await bindings.completedReceipts()
            let outputs = Dictionary(uniqueKeysWithValues: completed.keys.map { ($0, AutomationJSON.object(["disposition": .string("submittedUnconfirmed")])) })
            guard result == .object(["schemaVersion": .number(1), "scope": scope, "operationId": .string(program.operationID),
                                     "complete": .bool(true), "outputs": .object(outputs)]) else {
                throw AutomationSecretFillSession.Failure.outcomeUnresolved
            }
            return .object(["scope": scope, "complete": .bool(true), "outputs": .object(completed)])
        }
        var outputs: [String: AutomationJSON] = [:]
        for op in program.operations {
            try check(deadline)
            guard let reference = references[op.binding], case .string = reference else { throw AutomationSecretFillSession.Failure.denied }
            let response = try await bindings.handle(method: "secret.fillBinding", input: .object([
                "scope": scope, "operationId": .string(op.id), "binding": .string(op.binding), "referenceID": reference]))
            try check(deadline)
            guard response == .object(["scope": scope, "operationId": .string(op.id), "disposition": .string("submittedUnconfirmed")]) else {
                throw AutomationSecretFillSession.Failure.outcomeUnresolved
            }
            outputs[op.id] = response
        }
        try check(deadline)
        return .object(["scope": scope, "complete": .bool(true), "outputs": .object(outputs)])
    }
}
