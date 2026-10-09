#if os(macOS)
import Foundation

protocol AutomationMacProgramSession: Sendable {
    func open(programMode: Bool) async throws -> AutomationJSON
    func runProgram(_ program: AutomationUIProgram, phase: AutomationSegment.Phase, operationID: String) async throws -> AutomationJSON
    func close() async -> AutomationReleaseProof
}

/// Internal campaign route for the frozen development runtime.
actor AutomationMacUIRouteDriver: AutomationRouteDriver {
    struct SessionContext: Sendable {
        let app: AppIdentity
        let target: TargetIdentity
        let scope: AutomationScope
        let lease: AutomationDeviceLeaseManager.Lease
        let state: URL
        let authorize: AutomationMacNativeHelperBridge.Authorize
        let review: AutomationRPC.ReverseHandler
        let revalidate: @Sendable () async throws -> Void
    }
    typealias Factory = @Sendable (SessionContext) async throws -> any AutomationMacProgramSession
    private struct Control: Sendable {
        let scope: AutomationScope
        let lease: AutomationDeviceLeaseManager.Lease
        let segment: AutomationSegment
        var session: (any AutomationMacProgramSession)?
        var creation: Task<any AutomationMacProgramSession, any Error>?
        var instance: AutomationJSON?
        var acquired = false, executing = false
        var activation = false
        var inputPermit: AutomationMacInputPermit?
    }
    private let inputCapabilities: AutomationMacInputCapabilities
    private let root: URL, approval: RunApproval, leases: AutomationDeviceLeaseManager
    private let artifacts: AutomationArtifactRegistry, subject: any AutomationSubjectVerifier
    private let budget: AutomationCampaignBudget?, authority: AutomationRunAuthority, factory: Factory
    private var control: Control?
    private var reviewingPolicy = false
    private var acquiringScope: AutomationScope?
    private var acquiring: Bool { acquiringScope != nil }
    private var revoked: Set<Int> = []
    private var unreleased = false
    private var cleanup: Task<AutomationReleaseProof, Never>?
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    init(state: URL, approval: RunApproval, leases: AutomationDeviceLeaseManager, artifacts: AutomationArtifactRegistry,
         subject: any AutomationSubjectVerifier, campaignBudget: AutomationCampaignBudget?, inputCapabilities: AutomationMacInputCapabilities = .tapOnly, factory: @escaping Factory) throws {
        guard approval.target.kind == .nativeMac, approval.app.platform == "macos", approval.app.canonicalBundlePath != nil else {
            throw AutomationContractError.invalidIdentity
        }
        root = state; self.approval = approval; self.leases = leases; self.artifacts = artifacts; self.subject = subject
        budget = campaignBudget; authority = AutomationRunAuthority(approval: approval, leases: leases, artifacts: artifacts, campaignBudget: campaignBudget)
        self.factory = factory; self.inputCapabilities = inputCapabilities
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws {
        guard control == nil, !acquiring, !unreleased, !revoked.contains(lease.generation), plan.app == approval.app,
              plan.target == approval.target, plan.environmentID == approval.environmentID, plan.target.kind == .nativeMac,
              lease.control == .ui, lease.target == plan.target, lease.runID == approval.runID,
              scope.runId == approval.runID, scope.segmentId == segment.id, scope.leaseGeneration == lease.generation else {
            throw AutomationContractError.invalidIdentity
        }
        try AutomationMacUIProgramPreflight.validate(segment, capabilities: inputCapabilities)
        let program = segment.uiProgram!
        _ = try program.payload(scope: scope, phase: segment.phase, operationID: "\(scope.attemptId):\(scope.segmentId)")
        acquiringScope = scope; cleanup = nil; defer { acquiringScope = nil; settleWork() }
        try await subject.verify(app: plan.app, target: plan.target)
        try await requireCurrent(scope, lease)
        try await authority.approve(scope: scope, lease: lease, segment: segment, actions: program.approvedActions(),
            maximumControllerCalls: plan.budget.controllerCalls, maximumUIActions: plan.budget.uiActions)
        do { try await requireCurrent(scope, lease) }
        catch { try? await authority.revoke(scope: scope); throw error }
        control = .init(scope: scope, lease: lease, segment: segment)
        let directory = root.appendingPathComponent("control-\(lease.generation)")
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw AutomationContractError.ambiguousDispatch }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let context = SessionContext(app: plan.app, target: plan.target, scope: scope, lease: lease,
            state: directory,
            authorize: { try await self.authorize($0, scope: scope, lease: lease) },
            review: { await self.review($0, $1, scope: scope, lease: lease) },
            revalidate: { try await self.requireCurrent(scope, lease) })
        // Construction does not launch; open is the only dispatch admission.
        let factory = self.factory
        let creation = Task { try await factory(context) }
        control?.creation = creation
        let session = try await creation.value
        control?.session = session
        do {
            try await requireCurrent(scope, lease)
            guard control?.scope == scope else { throw AutomationContractError.unknownLease }
            let instance = try await session.open(programMode: true)
            try await requireCurrent(scope, lease)
            try AutomationMacNativeHelperBridge.validateInstance(instance, selection: .object([
                "bundleId": .string(plan.app.bundleID), "canonicalBundlePath": .string(plan.app.canonicalBundlePath!)]))
            _ = try await artifacts.store(data: JSONEncoder().encode(.object(["scope": try json(scope), "applicationTarget": instance]) as AutomationJSON),
                name: "mac-acquisition-\(lease.generation).json", scope: scope)
            try await requireCurrent(scope, lease)
            control?.instance = instance
            control?.acquired = true
        } catch {
            let proof = await Task.detached { await session.close() }.value
            unreleased = unreleased || !proof.commandsDrained || !proof.runnerTerminated
            throw error
        }
    }
    func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws -> AutomationSegmentReceipt {
        guard let active = control, active.scope == scope, active.lease == lease, active.segment == segment,
              active.acquired, !active.executing, plan.app == approval.app, plan.target == approval.target,
              plan.environmentID == approval.environmentID, let session = active.session, let instance = active.instance, let program = segment.uiProgram else {
            throw AutomationContractError.unknownLease
        }
        try await requireCurrent(scope, lease)
        control?.executing = true; defer { if control?.scope == scope { control?.executing = false }; settleWork() }
        let receipt = try await session.runProgram(program, phase: segment.phase, operationID: "\(scope.attemptId):\(scope.segmentId)")
        try await subject.verify(app: plan.app, target: plan.target)
        try await requireCurrent(scope, lease)
        guard let fields = receipt.object, Set(fields.keys) == ["schemaVersion", "scope", "operationId", "complete", "outputs"],
              fields["schemaVersion"] == .number(1), fields["scope"] == (try json(scope)), fields["complete"] == .bool(true),
              fields["operationId"] == .string("\(scope.attemptId):\(scope.segmentId)"), let outputs = fields["outputs"]?.object else {
            throw AutomationContractError.ambiguousDispatch
        }
        let expected = Set(program.operations.filter { [.readProperty, .locate, .observeProperty].contains($0.kind) }.map(\.id))
        guard Set(outputs.keys) == expected else { throw AutomationContractError.missingEvidence("Mac UI output scope mismatch") }
        for operation in program.operations {
            if operation.kind == .readProperty {
                guard outputs[operation.id] == .null || (outputs[operation.id]?.string.map { $0.utf16.count <= 32768 } ?? false) else {
                    throw AutomationContractError.missingEvidence("Invalid scalar UI readback")
                }
            } else if operation.kind == .locate {
                guard case .number(let count) = outputs[operation.id], count.rounded() == count, (0...5000).contains(count) else {
                    throw AutomationContractError.missingEvidence("Invalid UI locator result")
                }
            }
        }
        let (verified, _) = try await AutomationUIReadback.storeVerified(receipt: receipt, outputs: outputs, program: program,
            app: plan.app, target: plan.target, scope: scope, artifacts: artifacts, name: "mac-ui-\(lease.generation).json")
        let artifact = try await artifacts.store(data: JSONEncoder().encode(.object(["scope": try json(scope),
            "applicationTarget": instance, "receipt": receipt]) as AutomationJSON), name: "mac-execution-\(lease.generation).json", scope: scope)
        try await requireCurrent(scope, lease)
        var observations: [AutomationObservation] = []
        if segment.phase == .observe && !verified.isEmpty {
            var observed = AutomationObservation(id: segment.id, app: plan.app, target: plan.target, environmentID: plan.environmentID,
                attemptID: scope.attemptId, stepID: segment.id, route: .ui, proof: .visibleState, value: .object(verified))
            observed.artifact = artifact.handle; observations = [observed]
        }
        return .init(scope: scope, app: plan.app, target: plan.target, segmentID: segment.id, route: .ui,
            dispatched: true, completed: true, observations: observations, artifact: artifact.handle, verifiedOutputs: verified, environmentID: plan.environmentID)
    }
    func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async -> AutomationReleaseProof {
        guard lease.control == .ui, lease.target == approval.target, lease.runID == approval.runID,
              scope.runId == approval.runID, scope.leaseGeneration == lease.generation,
              acquiringScope.map({ $0 == scope }) ?? true,
              control.map({ $0.scope == scope && $0.lease == lease }) ?? true else {
            return .init(commandsDrained: false, runnerTerminated: false)
        }
        revoked.insert(lease.generation)
        if let cleanup { return await cleanup.value }
        let task = Task.detached { await self.finishRelease(scope: scope, lease: lease) }
        cleanup = task
        return await task.value
    }
    private func finishRelease(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async -> AutomationReleaseProof {
        try? await authority.revoke(scope: scope)
        guard let active = control else {
            await waitForWork()
            try? await authority.revoke(scope: scope)
            return .init(commandsDrained: !acquiring, runnerTerminated: !acquiring && !unreleased)
        }
        guard active.scope == scope, active.lease == lease else {
            return .init(commandsDrained: false, runnerTerminated: false)
        }
        active.creation?.cancel()
        let session: (any AutomationMacProgramSession)?
        if let owned = active.session { session = owned }
        else { session = try? await active.creation?.value }
        let proof = await session?.close() ?? .init(commandsDrained: true, runnerTerminated: true)
        await waitForWork()
        if proof.commandsDrained && proof.runnerTerminated && !acquiring && control?.executing != true && !unreleased {
            if proof.privatePayloadCleaned { control = nil }
            return proof
        }
        unreleased = true
        return .init(commandsDrained: proof.commandsDrained && !acquiring && control?.executing != true, runnerTerminated: false, privatePayloadCleaned: proof.privatePayloadCleaned)
    }
    private func waitForWork() async {
        if acquiring || control?.executing == true { await withCheckedContinuation { drainWaiters.append($0) } }
    }
    private func settleWork() {
        guard !acquiring, control?.executing != true else { return }
        let pending = drainWaiters; drainWaiters = []; pending.forEach { $0.resume() }
    }
    private func requireCurrent(_ scope: AutomationScope, _ lease: AutomationDeviceLeaseManager.Lease) async throws {
        try budget?.validateDeadline()
        guard !revoked.contains(lease.generation), await leases.isCurrent(lease), !revoked.contains(lease.generation) else {
            throw AutomationContractError.unknownLease
        }
        try Task.checkCancellation()
    }
    private func review(_ method: String, _ params: AutomationJSON, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async -> AutomationJSON {
        guard !reviewingPolicy else { return .object(["allowed": .bool(false), "reason": .string("routeBusy")]) }
        reviewingPolicy = true; defer { reviewingPolicy = false }
        do {
            try await requireCurrent(scope, lease)
            guard control?.scope == scope, acquiring || control?.executing == true else { throw AutomationContractError.unknownLease }
            if method == "policy.reviewAction", params.object?["action"] != nil {
                guard control?.executing == true, control?.inputPermit == nil else { throw AutomationContractError.conflictingOperation }
            }
            let reply = await authority.review(method: method, params: params)
            try await requireCurrent(scope, lease)
            guard control?.scope == scope else { throw AutomationContractError.unknownLease }
            if method == "policy.reviewAction", reply.object?["allowed"] == .bool(true) {
                if params.object?["effect"] == .string("activate") { control?.activation = true }
                else if let action = params.object?["action"] {
                    guard let permit = AutomationMacInputPermit(approvedAction: action) else { throw AutomationContractError.invalidIdentity }
                    control?.inputPermit = permit
                }
            }
            return reply
        } catch { return .object(["allowed": .bool(false), "reason": .string("routeRevoked")]) }
    }
    private func authorize(_ request: AutomationJSON, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws {
        try await requireCurrent(scope, lease)
        try await subject.verify(app: approval.app, target: approval.target)
        try await requireCurrent(scope, lease)
        guard let active = control, active.scope == scope, active.lease == lease,
              request.object?["scope"] == (try json(scope)),
              request.object?["selection"] == .object(["bundleId": .string(approval.app.bundleID), "canonicalBundlePath": .string(approval.app.canonicalBundlePath!)]),
              let kind = request.object?["action"]?.object?["kind"]?.string else { throw AutomationContractError.invalidIdentity }
        switch kind {
        case "acquire": guard acquiring, active.activation else { throw AutomationContractError.invalidIdentity }; control?.activation = false
        case "snapshot": guard active.executing else { throw AutomationContractError.invalidIdentity }
        case "press", "ordinaryFill", "scroll":
            guard active.executing, let permit = active.inputPermit, let action = request.object?["action"],
                  permit.matches(nativeAction: action) else { throw AutomationContractError.invalidIdentity }
            control?.inputPermit = nil
        default: throw AutomationContractError.invalidIdentity
        }
        try budget?.validateDeadline()
    }
    private func json<T: Encodable>(_ value: T) throws -> AutomationJSON { try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(value)) }
}
#endif
