import Foundation

/// Ephemeral native program. It contains opaque references, never credential values,
/// and cannot be imported as an ordinary UI program or historical capsule.
struct AutomationSecretFillProgram: Sendable {
    struct Operation: Encodable, Equatable, Sendable {
        let id: String
        let binding: String
        let kind = "fillSecretBinding"
    }
    let scope: AutomationScope
    let phase: AutomationSegment.Phase
    let operationID: String
    let operations: [Operation]
    let timeoutMilliseconds: Int
    init(scope: AutomationScope, phase: AutomationSegment.Phase, operationID: String,
         operations: [Operation], timeoutMilliseconds: Int = 30_000) throws {
        try scope.validate()
        guard phase != .observe, AutomationHostProgram.identifier(operationID), (1...30).contains(operations.count),
              Set(operations.map(\.id)).count == operations.count, Set(operations.map(\.binding)).count == operations.count,
              operations.allSatisfy({ AutomationHostProgram.identifier($0.id) && AutomationHostProgram.identifier($0.binding) }),
              (100...120_000).contains(timeoutMilliseconds) else { throw AutomationSecretFillSession.Failure.denied }
        self.scope = scope; self.phase = phase; self.operationID = operationID
        self.operations = operations; self.timeoutMilliseconds = timeoutMilliseconds
    }
}

/// One-use broker mapping owned by the trusted native consent path. No worker or
/// model can bind a value, mint consent, select a sink, or inspect a credential.
actor AutomationSecretFillBindings {
    private let program: AutomationSecretFillProgram
    private let session: AutomationSecretFillSession
    private var requests: [String: AutomationSecretFillRequest] = [:]
    private var reserved: Set<String> = []
    private var registrations: [String: Task<Void, Error>] = [:]
    private var references: Set<UUID> = []
    private var consumed: Set<String> = []
    private var completed: [String: AutomationJSON] = [:]
    private var revoked = false
    private var operation: Task<AutomationSecretFillSession.Receipt, Error>?

    init(program: AutomationSecretFillProgram, session: AutomationSecretFillSession) {
        self.program = program; self.session = session
    }
    func matchesProgram(_ expected: AutomationSecretFillProgram) -> Bool {
        program.scope == expected.scope && program.phase == expected.phase && program.operationID == expected.operationID
            && program.operations == expected.operations && program.timeoutMilliseconds == expected.timeoutMilliseconds
    }
    func register(_ request: AutomationSecretFillRequest, operationID: String) async throws {
        guard !revoked, operation == nil, request.scope == program.scope,
              program.operations.contains(where: { $0.id == operationID }), requests[operationID] == nil,
              !reserved.contains(operationID), !references.contains(request.reference.id) else {
            throw AutomationSecretFillSession.Failure.denied
        }
        // Reserve before independent current-lease checks suspend this actor.
        reserved.insert(operationID); references.insert(request.reference.id)
        let session = self.session, task = Task { try await session.validateBound(request) }
        registrations[operationID] = task
        defer { reserved.remove(operationID); registrations.removeValue(forKey: operationID) }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: {
                task.cancel(); Task { await self.revoke() }
            }
        } catch { references.remove(request.reference.id); throw AutomationSecretFillSession.Failure.denied }
        guard !Task.isCancelled, !revoked, operation == nil, requests[operationID] == nil else {
            throw AutomationSecretFillSession.Failure.revoked
        }
        requests[operationID] = request
    }
    func payload() throws -> AutomationJSON {
        guard !revoked, consumed.isEmpty, reserved.isEmpty, requests.count == program.operations.count else {
            throw AutomationSecretFillSession.Failure.denied
        }
        let bindings = Dictionary(uniqueKeysWithValues: program.operations.map { op in
            (op.binding, AutomationJSON.string(requests[op.id]!.reference.id.uuidString))
        })
        var body: [String: AutomationJSON] = ["scope": try json(program.scope), "operationId": .string(program.operationID),
            "phase": .string(program.phase.rawValue), "operations": try json(program.operations),
            "bindings": .object(bindings), "timeoutMs": .number(Double(program.timeoutMilliseconds))]
        body["payloadDigest"] = .string(AutomationArtifactRegistry.digest(try AutomationCanonicalJSON.encode(.object(body))))
        return .object(body)
    }
    func handle(method: String, input: AutomationJSON) async throws -> AutomationJSON {
        guard method == "secret.fillBinding", !revoked, operation == nil, reserved.isEmpty,
              requests.count == program.operations.count, let fields = input.object,
              Set(fields.keys) == ["scope", "operationId", "binding", "referenceID"],
              fields["scope"] == (try json(program.scope)), let id = fields["operationId"]?.string,
              let declared = program.operations.first(where: { $0.id == id }),
              fields["binding"] == .string(declared.binding), let request = requests[id], !consumed.contains(id),
              fields["referenceID"] == .string(request.reference.id.uuidString) else {
            throw AutomationSecretFillSession.Failure.denied
        }
        // Consume the mapping before any dispatch await, including uncertain delivery.
        consumed.insert(id)
        let session = self.session
        let task = Task { try await session.fill(request) }; operation = task
        defer { operation = nil }
        do {
            let receipt = try await withTaskCancellationHandler { try await task.value } onCancel: {
                task.cancel(); Task { await self.revoke() }
            }
            guard !revoked, !Task.isCancelled, receipt.request == request,
                  receipt.disposition == "submittedUnconfirmed" else { throw AutomationSecretFillSession.Failure.outcomeUnresolved }
            let response = AutomationJSON.object(["scope": try json(program.scope), "operationId": .string(id), "disposition": .string("submittedUnconfirmed")])
            completed[id] = response
            return response
        } catch {
            // Credential-bearing adapter errors never cross the opaque broker boundary.
            throw AutomationSecretFillSession.Failure.outcomeUnresolved
        }
    }
    func completedReceipts() throws -> [String: AutomationJSON] {
        guard !revoked, operation == nil, completed.count == program.operations.count,
              Set(completed.keys) == Set(program.operations.map(\.id)) else { throw AutomationSecretFillSession.Failure.outcomeUnresolved }
        return completed
    }
    func revoke() async {
        revoked = true; requests.removeAll(); completed.removeAll(); operation?.cancel()
        registrations.values.forEach { $0.cancel() }; await session.revoke()
    }
    func revokeAndDrain() async {
        let task = operation, pending = Array(registrations.values)
        await revoke()
        if let task { _ = await task.result }
        for task in pending { _ = await task.result }
        await session.revokeAndDrain()
    }
    private func json<T: Encodable>(_ value: T) throws -> AutomationJSON {
        try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(value))
    }
}
