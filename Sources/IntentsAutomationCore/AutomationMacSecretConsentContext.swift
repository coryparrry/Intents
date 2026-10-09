#if os(macOS)
import ApplicationServices
import Foundation

/// Native-owned qualification composition. No customer or imported-capsule entry.
/// The run authority must separately admit the exact opaque actions before run().
@MainActor final class AutomationMacSecretConsentContext<Element> {
    private let owner: AutomationMacSecureSink<Element>
    private let session: AutomationSecretFillSession
    private let bindings: AutomationSecretFillBindings
    private let executor: AutomationNativeSecretExecutor
    private let presenter: any AutomationSecretConsentPresenting
    private let operationID: String
    private var consentTask: Task<AutomationSecretFillRequest, Error>?
    private var cleanupTask: Task<Void, Never>?
    private var requested = false, registered = false, closed = false
    init(program: AutomationSecretFillProgram, session: AutomationSecretFillSession, owner: AutomationMacSecureSink<Element>,
         presenter: any AutomationSecretConsentPresenting, transport: AutomationSecretProgramTransport? = nil) throws {
        guard program.operations.count == 1, program.scope == owner.review.scope else { throw AutomationSecretFillSession.Failure.denied }
        self.owner = owner; self.session = session; self.presenter = presenter; operationID = program.operations[0].id
        let bindings = AutomationSecretFillBindings(program: program, session: session)
        self.bindings = bindings
        executor = AutomationNativeSecretExecutor(program: program, bindings: bindings, drainNativeOwner: { await owner.closeAndDrain() }, transport: transport)
    }
    func collectConsent() async throws -> AutomationSecretFillRequest {
        guard !closed, !requested, consentTask == nil else { throw AutomationSecretFillSession.Failure.denied }
        requested = true
        let task = Task {
            do {
                try await session.validateConsentContext(approval: owner.review.approval, scope: owner.review.scope)
                try await owner.validateConsent(owner.review)
                let request = try await presenter.present()
                try Task.checkCancellation()
                guard !closed, request.scope == owner.review.scope, request.sinkID == owner.review.sinkID,
                      request.sinkFingerprint == owner.review.sinkFingerprint else { throw AutomationSecretFillSession.Failure.denied }
                try await bindings.register(request, operationID: operationID)
                try Task.checkCancellation()
                guard !closed else { throw AutomationSecretFillSession.Failure.denied }
                registered = true; return request
            } catch {
                await presenter.cancelAndDrain(); await executor.closeAndDrain()
                throw AutomationSecretFillSession.Failure.denied
            }
        }
        consentTask = task
        defer { consentTask = nil }
        let request = try await withTaskCancellationHandler { try await task.value } onCancel: {
            task.cancel(); Task { await self.closeAndDrain() }
        }
        guard !closed, !Task.isCancelled, registered else { throw AutomationSecretFillSession.Failure.denied }
        return request
    }
    func run() async throws -> AutomationJSON {
        guard !closed, registered, consentTask == nil else { throw AutomationSecretFillSession.Failure.denied }
        let result = try await executor.run()
        guard !closed, !Task.isCancelled else { throw AutomationSecretFillSession.Failure.outcomeUnresolved }
        return result
    }
    func closeAndDrain() async {
        closed = true; registered = false
        let task = consentTask; task?.cancel()
        if let cleanupTask { await cleanupTask.value; return }
        let cleanup = Task {
            await presenter.cancelAndDrain(); await executor.closeAndDrain()
            if let task { _ = await task.result }
            await owner.closeAndDrain()
        }
        cleanupTask = cleanup; await cleanup.value
    }
}

extension AutomationMacSecretConsentContext where Element == AXUIElement {
    static func prepareOwnedWorker(approval: RunApproval, program: AutomationSecretFillProgram,
                                   lease: AutomationDeviceLeaseManager.Lease, leases: AutomationDeviceLeaseManager,
                                   authority: AutomationRunAuthority, artifacts: AutomationArtifactRegistry,
                                   unitRoot: URL, state: URL, x: Double, y: Double) async throws -> AutomationMacSecretConsentContext {
        let transport = try await AutomationMacSecretProgramTransport.owned(unitRoot: unitRoot, state: state, scope: program.scope, lease: lease, leases: leases)
        do {
            return try await prepare(approval: approval, program: program, lease: lease, leases: leases, authority: authority, artifacts: artifacts,
                                     x: x, y: y, transport: await transport.capability())
        } catch { _ = await transport.closeAndDrain(); throw AutomationSecretFillSession.Failure.denied }
    }
    static func prepare(approval: RunApproval, program: AutomationSecretFillProgram,
                        lease: AutomationDeviceLeaseManager.Lease, leases: AutomationDeviceLeaseManager,
                        authority: AutomationRunAuthority, artifacts: AutomationArtifactRegistry,
                        x: Double, y: Double, transport: AutomationSecretProgramTransport? = nil) async throws -> AutomationMacSecretConsentContext {
        let evidenceRoot = await artifacts.secretEvidenceRoot()
        guard program.operations.count == 1, lease.runID == approval.runID, lease.target == approval.target,
              lease.control == .ui, program.scope.runId == approval.runID, program.scope.leaseGeneration == lease.generation,
              await leases.isDurable, await leases.isCurrent(lease),
              await authority.matchesSecretContext(approval, evidenceRoot: evidenceRoot) else {
            throw AutomationSecretFillSession.Failure.denied
        }
        let fence = try await leases.nativeInputFence(for: lease)
        let owner = try await AutomationMacSecureFill.capture(approval: approval, scope: program.scope, leaseFence: fence, x: x, y: y)
        let session = AutomationSecretFillSession(approval: approval, lease: lease, leases: leases, authority: authority,
            artifacts: artifacts, adapter: await owner.adapter())
        let model = AutomationSecretConsentModel(review: owner.review, session: session, validateSink: { try await owner.validateConsent($0) })
        let presenter = AutomationSecretConsentPresenter(model: model, drainNativeOwner: { await owner.closeAndDrain() })
        return try .init(program: program, session: session, owner: owner, presenter: presenter, transport: transport)
    }
}
#endif
