#if os(macOS)
import Foundation
import Observation

/// Owned native review data. Controllers and imported capsules cannot construct consent UI.
struct AutomationSecretConsentReview: Sendable {
    let approval: RunApproval
    let scope: AutomationScope
    let sinkID: String
    let sinkFingerprint: String
    init(approval: RunApproval, scope: AutomationScope, sinkID: String, sinkFingerprint: String) throws {
        try scope.validate()
        guard approval.app.platform == "macos", approval.app.productDigestVersion == 2,
              approval.app.productDigest?.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              approval.app.canonicalBundlePath != nil, approval.target.kind == .nativeMac,
              approval.target.id == "host-macos-local", approval.target.loginSession?.isEmpty == false,
              approval.approvedCaseDigest?.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              scope.runId == approval.runID, approval.effects.contains(.navigate),
              approval.effects.contains(.externalWrite) || (approval.effects.contains(.fixtureWrite) && approval.disposable),
              AutomationHostProgram.identifier(sinkID), sinkFingerprint.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            throw AutomationSecretFillSession.Failure.denied
        }
        self.approval = approval; self.scope = scope; self.sinkID = sinkID; self.sinkFingerprint = sinkFingerprint
    }
}

/// No credential is stored in observable state. The retained operation owns native
/// validation and binding work until cancellation actually drains it.
@MainActor @Observable final class AutomationSecretConsentModel {
    enum State: Equatable { case idle, verifying, ready, authorizing, approved, cancelled, failed }
    let review: AutomationSecretConsentReview
    private(set) var state: State = .idle
    @ObservationIgnored private let session: AutomationSecretFillSession
    @ObservationIgnored private let validateSink: @Sendable (AutomationSecretConsentReview) async throws -> Void
    @ObservationIgnored private var operation: Task<AutomationSecretFillRequest?, Error>?
    @ObservationIgnored private var generation = UUID()

    init(review: AutomationSecretConsentReview, session: AutomationSecretFillSession,
         validateSink: @escaping @Sendable (AutomationSecretConsentReview) async throws -> Void) {
        self.review = review; self.session = session; self.validateSink = validateSink
    }
    func prepare() async throws {
        guard operation == nil, state == .idle || state == .failed else { throw AutomationSecretFillSession.Failure.denied }
        state = .verifying; let token = UUID(); generation = token
        let review = self.review, session = self.session, validate = self.validateSink
        let task = Task<AutomationSecretFillRequest?, Error> {
            try await session.validateConsentContext(approval: review.approval, scope: review.scope)
            try await validate(review)
            try Task.checkCancellation()
            // Withhold shared evidence before a native credential field can collect input.
            try await session.beginConsentEvidence(approval: review.approval, scope: review.scope)
            return nil
        }
        operation = task
        defer { if generation == token { operation = nil } }
        do {
            _ = try await value(task)
            guard generation == token, !Task.isCancelled, state == .verifying else { throw AutomationSecretFillSession.Failure.revoked }
            state = .ready
        } catch {
            if generation == token, state != .cancelled { state = .failed }
            throw AutomationSecretFillSession.Failure.denied
        }
    }
    func confirm(_ secret: String) async throws -> AutomationSecretFillRequest {
        guard operation == nil, state == .ready, !secret.isEmpty, secret.utf16.count <= 32768 else {
            throw AutomationSecretFillSession.Failure.denied
        }
        state = .authorizing; let token = UUID(); generation = token
        let review = self.review, session = self.session, validate = self.validateSink
        let task = Task<AutomationSecretFillRequest?, Error> {
            try await session.validateConsentContext(approval: review.approval, scope: review.scope)
            try await validate(review)
            try Task.checkCancellation()
            try await session.validateConsentContext(approval: review.approval, scope: review.scope)
            let request = try await session.bind(secret, consent: .init(approval: review.approval, scope: review.scope,
                sinkID: review.sinkID, sinkFingerprint: review.sinkFingerprint, expires: .now + .seconds(60), maximumUses: 1))
            try await session.validateBound(request)
            return request
        }
        operation = task
        defer { if generation == token { operation = nil } }
        do {
            let request = try await value(task)
            guard generation == token, !Task.isCancelled, state == .authorizing, let request else {
                throw AutomationSecretFillSession.Failure.revoked
            }
            state = .approved; return request
        } catch {
            if generation == token, state != .cancelled { state = .failed }
            // Failed/cancelled binding cannot leave an undisclosed live credential entry.
            await session.revokeAndDrain()
            throw AutomationSecretFillSession.Failure.denied
        }
    }
    func cancelAndDrain() async {
        state = .cancelled; generation = UUID()
        let task = operation; task?.cancel()
        await session.revoke()
        if let task { _ = await task.result }
        await session.revokeAndDrain(); operation = nil
    }
    private func value(_ task: Task<AutomationSecretFillRequest?, Error>) async throws -> AutomationSecretFillRequest? {
        try await withTaskCancellationHandler { try await task.value } onCancel: {
            task.cancel(); Task { await self.cancelAndDrain() }
        }
    }
}
#endif
