#if os(macOS)
import Foundation

/// Native-only retained field ownership. The fingerprint includes a fresh nonce;
/// equivalence still requires the actual retained object, never coordinates alone.
actor AutomationMacSecureSink<Element> {
    struct Dependencies: Sendable {
        let checkInputOwnership: @Sendable () throws -> Void
        let validateContext: @Sendable () async throws -> Void
        let resolve: @Sendable () throws -> Element
        let verify: @Sendable (Element) throws -> Void
        let same: @Sendable (Element, Element) -> Bool
        let replace: @Sendable (Element, String) throws -> Void
    }
    nonisolated let review: AutomationSecretConsentReview
    private let dependencies: Dependencies
    private let timeout: Duration
    private nonisolated let revocation = AutomationNativeTaskRevocation<Void>()
    private var retained: Element?
    private var closed = false, consumed = false
    private var operation: Task<Void, Error>?

    init(approval: RunApproval, scope: AutomationScope, dependencies: Dependencies, timeout: Duration = .seconds(5)) throws {
        guard timeout > .zero, timeout <= .seconds(5) else { throw AutomationSecretFillSession.Failure.denied }
        let nonce = UUID().uuidString.lowercased()
        review = try .init(approval: approval, scope: scope, sinkID: "secure-field-" + nonce,
            sinkFingerprint: AutomationArtifactRegistry.digest(Data(nonce.utf8)))
        self.dependencies = dependencies; self.timeout = timeout
    }
    func open() async throws {
        guard retained == nil, !consumed else { throw AutomationSecretFillSession.Failure.denied }
        try await run { owner in try await owner.checkFresh(allowPin: true) }
    }
    func validateConsent(_ value: AutomationSecretConsentReview) async throws {
        guard matches(value) else { throw AutomationSecretFillSession.Failure.denied }
        try await run { owner in try await owner.checkFresh() }
    }
    func adapter() -> AutomationSecretFillAdapter {
        .init(validateSink: { request, approval in try await self.validate(request, approval: approval) },
              submit: { secret, request, approval in try await self.submit(secret, request: request, approval: approval) })
    }
    nonisolated func closeAndDrain() async {
        // Cancels a synchronous native check before waiting for this actor's executor.
        revocation.revoke()
        await closeOnActorAndDrain()
    }
    private func closeOnActorAndDrain() async {
        closed = true; retained = nil
        let task = operation; task?.cancel()
        if let task { _ = await task.result }
        operation = nil
    }
    private func matches(_ value: AutomationSecretConsentReview) -> Bool {
        value.approval == review.approval && value.scope == review.scope && value.sinkID == review.sinkID && value.sinkFingerprint == review.sinkFingerprint
    }
    private func matches(_ request: AutomationSecretFillRequest, approval: RunApproval) -> Bool {
        approval == review.approval && request.scope == review.scope && request.sinkID == review.sinkID && request.sinkFingerprint == review.sinkFingerprint
    }
    private func validate(_ request: AutomationSecretFillRequest, approval: RunApproval) async throws {
        guard matches(request, approval: approval), !consumed else { throw AutomationSecretFillSession.Failure.denied }
        try await run { owner in try await owner.checkFresh() }
    }
    private func submit(_ secret: String, request: AutomationSecretFillRequest, approval: RunApproval) async throws {
        guard matches(request, approval: approval), !consumed, !secret.isEmpty, secret.utf16.count <= 32768,
              operation == nil, !closed else { throw AutomationSecretFillSession.Failure.denied }
        // Consume before any fresh check or potentially uncertain write. Never retry.
        consumed = true
        defer { retained = nil }
        try await run { owner in try await owner.deliver(secret) }
    }
    private func deliver(_ secret: String) async throws {
        try await checkFresh()
        guard !closed, !Task.isCancelled, let retained else { throw AutomationSecretFillSession.Failure.denied }
        try AutomationNativeSecretDeadline.check()
        try dependencies.checkInputOwnership()
        try AutomationNativeSecretDeadline.check()
        try dependencies.replace(retained, secret)
        try AutomationNativeSecretDeadline.check()
        // Metadata/identity only after submission. Never read a secure value.
        try await checkFresh()
    }
    private func checkFresh(allowPin: Bool = false) async throws {
        try AutomationNativeSecretDeadline.check()
        guard !closed else { throw AutomationSecretFillSession.Failure.denied }
        try dependencies.checkInputOwnership()
        try await dependencies.validateContext()
        try AutomationNativeSecretDeadline.check()
        guard !closed else { throw AutomationSecretFillSession.Failure.denied }
        let fresh = try dependencies.resolve()
        try dependencies.verify(fresh)
        try AutomationNativeSecretDeadline.check()
        if let retained {
            guard dependencies.same(retained, fresh) else { throw AutomationSecretFillSession.Failure.denied }
            try dependencies.verify(retained)
        } else {
            guard allowPin else { throw AutomationSecretFillSession.Failure.denied }
            retained = fresh
        }
        try AutomationNativeSecretDeadline.check()
        try dependencies.checkInputOwnership()
    }
    private func run(_ body: @escaping @Sendable (AutomationMacSecureSink) async throws -> Void) async throws {
        guard !closed, !revocation.isRevoked, operation == nil else { throw AutomationSecretFillSession.Failure.denied }
        let ownDeadline = ContinuousClock.now.advanced(by: timeout)
        let deadline = min(ownDeadline, AutomationNativeSecretDeadline.value ?? ownDeadline)
        let task = Task {
            try await AutomationNativeSecretDeadline.$value.withValue(deadline) {
                try await body(self); try AutomationNativeSecretDeadline.check()
            }
        }
        operation = task
        guard revocation.install(task) else { task.cancel(); _ = await task.result; operation = nil; throw AutomationSecretFillSession.Failure.denied }
        defer { operation = nil; revocation.retire() }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: {
                task.cancel(); Task { await self.closeAndDrain() }
            }
            guard !closed, !revocation.isRevoked, !Task.isCancelled else { throw AutomationSecretFillSession.Failure.denied }
        } catch { throw AutomationSecretFillSession.Failure.denied }
    }
}
#endif
