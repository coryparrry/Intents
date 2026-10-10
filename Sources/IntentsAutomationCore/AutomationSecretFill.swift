import Foundation

/// Data-only identity. The credential is never a Codable program binding.
struct AutomationSecretReference: Codable, Equatable, Sendable {
    let id: UUID
}

struct AutomationSecretFillRequest: Codable, Equatable, Sendable {
    let reference: AutomationSecretReference
    let scope: AutomationScope
    let sinkID: String
    let sinkFingerprint: String
}

/// Created by the trusted consent UI, not by a controller or imported capsule.
struct AutomationSecretFillConsent: Sendable {
    let approval: RunApproval
    let scope: AutomationScope
    let sinkID: String
    let sinkFingerprint: String
    let expires: ContinuousClock.Instant
    let maximumUses: Int
}

/// An injected adapter must independently verify the exact fresh secure field.
/// It is responsible for owning and draining its dispatch, without logging input.
struct AutomationSecretFillAdapter: Sendable {
    let validateSink: @Sendable (AutomationSecretFillRequest, RunApproval) async throws -> Void
    let submit: @Sendable (String, AutomationSecretFillRequest, RunApproval) async throws -> Void
}

/// Internal qualification path only. Ordinary SDK filling remains unavailable
/// for credentials until its captures, logs and cancellation are qualified.
actor AutomationSecretFillSession {
    enum Failure: Error, Equatable { case denied, unavailable, revoked, outcomeUnresolved }
    struct Receipt: Codable, Equatable, Sendable {
        let request: AutomationSecretFillRequest
        let disposition: String
    }
    private struct Entry {
        let secret: String
        let consent: AutomationSecretFillConsent
        var consumed = false
    }
    private let approval: RunApproval
    private let lease: AutomationDeviceLeaseManager.Lease
    private let isCurrent: @Sendable () async -> Bool
    private let authority: AutomationRunAuthority
    private let artifacts: AutomationArtifactRegistry
    private let adapter: AutomationSecretFillAdapter?
    private let now: @Sendable () -> ContinuousClock.Instant
    private var entries: [UUID: Entry] = [:]
    private var revoked = false
    private var busy = false
    private var operation: Task<Receipt, Error>?

    init(approval: RunApproval, lease: AutomationDeviceLeaseManager.Lease,
         leases: AutomationDeviceLeaseManager, authority: AutomationRunAuthority,
         artifacts: AutomationArtifactRegistry, adapter: AutomationSecretFillAdapter? = nil,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
         isCurrent: (@Sendable () async -> Bool)? = nil) {
        self.approval = approval; self.lease = lease
        self.isCurrent = isCurrent ?? { await leases.isCurrent(lease) }
        self.authority = authority; self.artifacts = artifacts; self.adapter = adapter; self.now = now
    }

    func bind(_ secret: String, consent: AutomationSecretFillConsent) async throws -> AutomationSecretFillRequest {
        let evidenceRoot = await artifacts.secretEvidenceRoot()
        guard await authority.matchesSecretContext(approval, evidenceRoot: evidenceRoot) else { throw Failure.denied }
        try consent.scope.validate()
        let instant = now()
        guard !revoked, entries.count < 64, !secret.isEmpty, secret.utf16.count <= 32768,
              consent.approval == approval, consent.scope.runId == approval.runID,
              consent.scope.leaseGeneration == lease.generation, lease.runID == approval.runID,
              lease.target == approval.target, lease.control == .ui, !approval.environmentID.isEmpty,
              approval.effects.contains(.navigate),
              approval.effects.contains(.fixtureWrite) || approval.effects.contains(.externalWrite),
              consent.maximumUses == 1, instant < consent.expires,
              consent.expires - instant <= .seconds(300),
              consent.sinkID.utf8.count <= 256,
              consent.sinkID.range(of: #"^[A-Za-z0-9_.:-]+$"#, options: .regularExpression) != nil,
              consent.sinkFingerprint.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
        else { throw Failure.denied }
        let reference = AutomationSecretReference(id: UUID())
        entries[reference.id] = Entry(secret: secret, consent: consent)
        return .init(reference: reference, scope: consent.scope, sinkID: consent.sinkID,
                     sinkFingerprint: consent.sinkFingerprint)
    }

    /// Trusted native UI checks current ownership before collecting or binding input.
    func validateConsentContext(approval expected: RunApproval, scope: AutomationScope) async throws {
        try scope.validate()
        let evidenceRoot = await artifacts.secretEvidenceRoot()
        guard !Task.isCancelled, !revoked, expected == approval, scope.runId == approval.runID,
              scope.leaseGeneration == lease.generation, lease.runID == approval.runID,
              lease.target == approval.target, lease.control == .ui, !approval.environmentID.isEmpty,
              await authority.matchesSecretContext(approval, evidenceRoot: evidenceRoot), await isCurrent() else { throw Failure.denied }
        guard !Task.isCancelled, !revoked else { throw Failure.revoked }
    }
    func beginConsentEvidence(approval expected: RunApproval, scope: AutomationScope) async throws {
        try await validateConsentContext(approval: expected, scope: scope)
        try await artifacts.restrictSecretEvidence(scope: scope)
        try await validateConsentContext(approval: expected, scope: scope)
    }

    /// Native mapping admission checks the existing consent without resolving its value.
    func validateBound(_ request: AutomationSecretFillRequest) async throws { try await check(request) }

    func fill(_ request: AutomationSecretFillRequest) async throws -> Receipt {
        guard let adapter else { throw Failure.unavailable }
        guard !busy else { throw Failure.denied }
        busy = true
        let task = Task { try await self.execute(request, adapter: adapter) }
        operation = task
        defer { operation = nil; busy = false }
        return try await withTaskCancellationHandler { try await task.value } onCancel: {
            task.cancel()
            Task { await self.revoke() }
        }
    }

    private func execute(_ request: AutomationSecretFillRequest, adapter: AutomationSecretFillAdapter) async throws -> Receipt {
        // Secret resolution occurs in the retained dispatch task, after fresh
        // sink validation, consent, shared authority and current lease checks.
        try await check(request)
        do { try await adapter.validateSink(request, approval) } catch { throw Failure.denied }
        try await check(request)
        try await artifacts.restrictSecretEvidence(scope: request.scope)
        try await check(request)
        let action: AutomationJSON = .object(["kind": .string("fillSecret"),
            "referenceID": .string(request.reference.id.uuidString), "sinkID": .string(request.sinkID)])
        var fields = try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(request.scope)).object!
        fields["action"] = action
        let allowed = await authority.review(method: "policy.reviewAction", params: .object(fields))
        guard allowed == .object(["allowed": .bool(true)]) else { throw Failure.denied }
        try await check(request)
        // Any admitted attempt consumes consent, including uncertain delivery.
        var entry = entries[request.reference.id]!
        entry.consumed = true; entries[request.reference.id] = entry
        defer { entries.removeValue(forKey: request.reference.id) }
        do {
            try await adapter.submit(entry.secret, request, approval)
            guard !revoked, !Task.isCancelled, now() < entry.consent.expires,
                  await isCurrent() else { throw Failure.outcomeUnresolved }
            guard !revoked, !Task.isCancelled, now() < entry.consent.expires else { throw Failure.outcomeUnresolved }
            // Dispatch completion is not an app persistence assertion.
            return .init(request: request, disposition: "submittedUnconfirmed")
        } catch {
            // Adapter errors/causes may contain credentials: never serialize them.
            throw Failure.outcomeUnresolved
        }
    }

    func revoke() {
        revoked = true; entries.removeAll(); operation?.cancel()
    }

    func revokeAndDrain() async {
        revoke()
        if let task = operation { _ = await task.result }
    }

    private func check(_ request: AutomationSecretFillRequest) async throws {
        let evidenceRoot = await artifacts.secretEvidenceRoot()
        guard !Task.isCancelled, !revoked, let entry = entries[request.reference.id], !entry.consumed,
              entry.consent.scope == request.scope, entry.consent.sinkID == request.sinkID,
              entry.consent.sinkFingerprint == request.sinkFingerprint, now() < entry.consent.expires,
              await authority.matchesSecretContext(approval, evidenceRoot: evidenceRoot), await isCurrent() else { throw Failure.denied }
        // Reentrancy can revoke or expire consent while querying the lease.
        guard !Task.isCancelled, !revoked, entries[request.reference.id]?.consumed == false,
              now() < entry.consent.expires else { throw Failure.revoked }
    }
}
