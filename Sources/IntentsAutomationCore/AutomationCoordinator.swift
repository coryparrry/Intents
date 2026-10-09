import Foundation

public struct AutomationSegmentReceipt: Codable, Equatable, Sendable {
    public var scope: AutomationScope
    public var app: AppIdentity
    public var target: TargetIdentity
    public var segmentID: String
    public var route: AutomationSegment.Kind
    public var dispatched: Bool
    public var completed: Bool
    public var observations: [AutomationObservation]
    public var artifact: String?
    public var verifiedOutputs: [String: AutomationValue]?
    public var environmentID: String?
    var hostReceiptDigest: String? = nil
    public init(scope: AutomationScope, app: AppIdentity, target: TargetIdentity, segmentID: String,
                route: AutomationSegment.Kind, dispatched: Bool, completed: Bool, observations: [AutomationObservation] = [], artifact: String? = nil, verifiedOutputs: [String: AutomationValue]? = nil, environmentID: String? = nil) {
        self.scope = scope; self.app = app; self.target = target; self.segmentID = segmentID; self.route = route
        self.dispatched = dispatched; self.completed = completed; self.observations = observations; self.artifact = artifact; self.verifiedOutputs = verifiedOutputs
        self.environmentID = environmentID
    }
}
public struct AutomationReleaseProof: Sendable {
    public var commandsDrained: Bool
    public var runnerTerminated: Bool
    public var privatePayloadCleaned: Bool
    public init(commandsDrained: Bool, runnerTerminated: Bool, privatePayloadCleaned: Bool = true) {
        self.commandsDrained = commandsDrained; self.runnerTerminated = runnerTerminated; self.privatePayloadCleaned = privatePayloadCleaned
    }
}
public protocol AutomationRouteDriver: Sendable {
    func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope,
                 lease: AutomationDeviceLeaseManager.Lease) async throws
    func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope,
                 lease: AutomationDeviceLeaseManager.Lease) async throws -> AutomationSegmentReceipt
    func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async -> AutomationReleaseProof
}
public struct AutomationAttemptReport: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var attemptID: String
    public var result: AttemptResult
    public var receipts: [AutomationSegmentReceipt]
    public var resourcesReleased: Bool
    var receipt: AutomationSegmentReceipt?
    public var executionSucceeded: Bool {
        resourcesReleased && result.subjectDispatched && result.subjectCompleted && !result.subjectDispatchUncertain
            && result.evidenceComplete && [.passed, .executedUnassessed].contains(result.summary)
    }
}

/// The native owner sequences independent controllers; driver receipts never supply a business verdict.
public actor AutomationCoordinator {
    private let leases: AutomationDeviceLeaseManager
    private let journal: AutomationJournal
    private let cleanupTimeout: Duration
    private let campaignDeadline: ContinuousClock.Instant?
    private var running = false
    public init(leases: AutomationDeviceLeaseManager, journal: AutomationJournal) {
        self.leases = leases; self.journal = journal; cleanupTimeout = .seconds(90); campaignDeadline = nil
    }
    init(leases: AutomationDeviceLeaseManager, journal: AutomationJournal, cleanupTimeout: Duration, campaignDeadline: ContinuousClock.Instant? = nil) throws {
        guard cleanupTimeout > .zero, cleanupTimeout <= .seconds(90) else { throw AutomationContractError.invalidIdentity }
        self.leases = leases; self.journal = journal; self.cleanupTimeout = cleanupTimeout; self.campaignDeadline = campaignDeadline
    }
    public func run(plan: AutomationCase, approval: RunApproval, capabilities: CapabilityProfile,
                    attemptID: String, driver: any AutomationRouteDriver, fixtureTracker: AutomationFreshFixtureTracker? = nil, qualificationFence: AutomationFreshFixtureQualificationFence? = nil, siriAuthority: AutomationSiriRouteAuthority? = nil) async throws -> AutomationAttemptReport {
        guard !running else { throw AutomationContractError.targetBusy }
        running = true; defer { running = false }
        try PlanValidator.validate(plan, approval: approval, capabilities: capabilities, siriAuthority: siriAuthority)
        guard !attemptID.isEmpty else { throw AutomationContractError.invalidIdentity }
        let planDeadline = ContinuousClock.now.advanced(by: .seconds(plan.budget.wallClockSeconds))
        let deadline = min(planDeadline, campaignDeadline ?? planDeadline)
        var receipts: [AutomationSegmentReceipt] = [], subjectDispatched = false, subjectCompleted = false
        var termination: AttemptResult.Summary?, released = true, dispatchUncertain = false
        var policyDenial: AutomationPolicyDenialReason?
        let segments = plan.setup + [plan.execution] + plan.observations
        for segment in segments {
            do {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { termination = .timedOut; break }
                if segment.phase == .subject, let qualificationFence {
                    try await qualificationFence.reserveBeforeSubject(receipts: receipts, plan: plan, approval: approval, attemptID: attemptID)
                }
                if segment.phase == .subject, let fixtureTracker {
                    try await fixtureTracker.reserveBeforeSubject(receipts: receipts, plan: plan, approval: approval, attemptID: attemptID)
                }
                let resolution = try AutomationInputResolver.resolveForExecution(segment: segment, receipts: receipts, plan: plan, runID: approval.runID, attemptID: attemptID)
                let (receipt, controlReleased) = try await execute(plan: plan, segment: resolution.segment, resolution: resolution.authority, approval: approval, attemptID: attemptID, deadline: deadline, driver: driver)
                receipts.append(receipt)
                if segment.phase == .subject { subjectDispatched = receipt.dispatched; subjectCompleted = receipt.completed }
                if !controlReleased { released = false; termination = .unresolved; break }
                if !receipt.completed { termination = segment.phase == .setup ? .invalidFixture : .unresolved; break }
                if segment.phase == .setup, !AutomationFixtureValidator.validates(receipt: receipt, segment: resolution.segment, plan: plan, runID: approval.runID, attemptID: attemptID) {
                    termination = .invalidFixture; break
                }
            } catch {
                if let failure = error as? AutomationExecutionFailure {
                    if let receipt = failure.receipt {
                        receipts.append(receipt)
                        if segment.phase == .subject { subjectDispatched = receipt.dispatched; subjectCompleted = receipt.completed }
                    }
                    if segment.phase == .subject { dispatchUncertain = failure.dispatchUncertain }
                    released = failure.resourcesReleased; termination = failure.summary; policyDenial = failure.policyDenial
                } else { termination = error is AutomationFixtureFreshnessError ? .invalidFixture : error is AutomationInputBindingError ? .inputUnavailable : error is CancellationError ? .cancelled : segment.phase == .setup ? .invalidFixture : .unresolved }
                break
            }
        }
        // An unresolved controller or cancellation cannot authorize another device mutation.
        if released && termination == nil {
            for segment in plan.cleanup {
                do {
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline else { termination = .timedOut; break }
                    let resolution = try AutomationInputResolver.resolveForExecution(segment: segment, receipts: receipts, plan: plan, runID: approval.runID, attemptID: attemptID)
                    let (receipt, controlReleased) = try await execute(plan: plan, segment: resolution.segment, resolution: resolution.authority, approval: approval, attemptID: attemptID, deadline: deadline, driver: driver)
                    receipts.append(receipt)
                    if !controlReleased || !receipt.completed { termination = .unresolved; released = controlReleased; break }
                } catch {
                    if let failure = error as? AutomationExecutionFailure {
                        if let receipt = failure.receipt { receipts.append(receipt) }
                        termination = failure.summary; released = failure.resourcesReleased; policyDenial = failure.policyDenial
                    } else { termination = error is CancellationError ? .cancelled : .unresolved; released = false }
                    break
                }
            }
        }
        if released { do { try await leases.releaseCampaign(runID: approval.runID, target: plan.target) } catch { released = false } }
        if !released && termination == nil { termination = .unresolved }
        let observations = receipts.filter { receipt in
            plan.observations.contains { $0.id == receipt.segmentID && $0.kind == receipt.route }
        }.flatMap(\.observations)
        var result = AutomationAssessment.assess(plan: plan, attemptID: attemptID, subjectDispatched: subjectDispatched,
                                                subjectCompleted: subjectCompleted, observations: observations, receipts: receipts, runID: approval.runID, termination: termination)
        if let termination, subjectCompleted { result.summary = termination; result.evidenceComplete = false; result.assessed = false }
        result.subjectDispatchUncertain = dispatchUncertain
        result.policyDenial = policyDenial
        return AutomationAttemptReport(attemptID: attemptID, result: result, receipts: receipts, resourcesReleased: released)
    }
    private func execute(plan: AutomationCase, segment: AutomationSegment, resolution: AutomationSegmentResolutionAuthority, approval: RunApproval,
                         attemptID: String, deadline: ContinuousClock.Instant, driver: any AutomationRouteDriver) async throws -> (AutomationSegmentReceipt, Bool) {
        let control: AutomationDeviceLeaseManager.Lease.Control = segment.kind == .ui ? .ui : .system
        let lease = try await leases.acquire(runID: approval.runID, target: plan.target, control: control)
        let scope = AutomationScope(runID: approval.runID, attemptID: attemptID, segmentID: segment.id, leaseGeneration: lease.generation)
        var invoked = false, alreadyReleased = false
        var knownReceipt: AutomationSegmentReceipt?
        let acquisition = AutomationBoundedTask<Bool>()
        let execution = AutomationBoundedTask<AutomationSegmentReceipt>()
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let digest = AutomationArtifactRegistry.digest(try encoder.encode(segment))
            let operationID = "\(approval.runID):\(attemptID):\(segment.id)"
            guard try await journal.begin(operationID: operationID, digest: digest) == nil else {
                throw AutomationContractError.ambiguousDispatch
            }
            try await leases.recordDispatch(.init(scope: scope, operationID: operationID, payloadDigest: digest), lease: lease)
            _ = try await acquisition.run(until: deadline) {
                if let resolvedDriver = driver as? any AutomationResolvedRouteDriver {
                    try await resolvedDriver.acquireResolved(plan: plan, segment: segment, scope: scope, lease: lease, authority: resolution)
                } else { try await driver.acquire(plan: plan, segment: segment, scope: scope, lease: lease) }
                return true
            }
            invoked = true
            let receipt = try await execution.run(until: deadline) {
                try await driver.execute(plan: plan, segment: segment, scope: scope, lease: lease)
            }
            guard receipt.scope == scope, receipt.app == plan.app, receipt.target == plan.target,
                  receipt.segmentID == segment.id, receipt.route == segment.kind, !receipt.completed || receipt.dispatched,
                  receipt.environmentID == nil || receipt.environmentID == plan.environmentID else {
                throw AutomationContractError.ambiguousDispatch
            }
            knownReceipt = receipt
            let controlReleased = await release(driver: driver, scope: scope, lease: lease, workDrained: { true })
            guard controlReleased else { return (receipt, false) }
            alreadyReleased = true
            if receipt.completed { try await journal.complete(operationID: operationID, digest: digest, response: .bool(true)) }
            return (receipt, true)
        } catch {
            let acquisitionStarted = await acquisition.started
            let duplicate = !acquisitionStarted && error as? AutomationContractError == .ambiguousDispatch
            let controlReleased: Bool
            if alreadyReleased { controlReleased = true }
            else if duplicate {
                do { try await leases.release(lease, commandsDrained: true, ownedRunnerTerminated: true); controlReleased = true }
                catch { controlReleased = false }
            } else {
                let executionInvoked = invoked
                controlReleased = await release(driver: driver, scope: scope, lease: lease, workDrained: {
                    let acquired = await acquisition.workFinished
                    let executed = await execution.workFinished
                    return (!executionInvoked && (!acquisitionStarted || acquired)) || (executionInvoked && acquired && executed)
                })
            }
            let summary: AttemptResult.Summary = error is CancellationError ? .cancelled
                : error as? AutomationRPCError == .timedOut ? .timedOut : segment.phase == .setup ? .invalidFixture : .unresolved
            throw AutomationExecutionFailure(summary: summary, dispatchUncertain: knownReceipt == nil && (invoked || duplicate), resourcesReleased: controlReleased, receipt: knownReceipt, policyDenial: AutomationPolicyDenialReason.from(error))
        }
    }
    private func release(driver: any AutomationRouteDriver, scope: AutomationScope,
                         lease: AutomationDeviceLeaseManager.Lease, workDrained: @escaping @Sendable () async -> Bool) async -> Bool {
        let allocator = leases
        let cleanupTimeout = cleanupTimeout
        return await Task.detached {
        let shutdown = AutomationBoundedTask<AutomationReleaseProof>()
        do {
            // The private sidecar has bounded shutdown (45s), process exit
            // (10s + 5s) and independent device readback (15s) plus inspector termination stages. Allow
            // that cleanup envelope without extending or retrying execution.
            let proof = try await shutdown.run(until: ContinuousClock.now.advanced(by: cleanupTimeout)) {
                await driver.release(scope: scope, lease: lease)
            }
            guard await workDrained(), proof.privatePayloadCleaned else { return false }
            try await allocator.release(lease, commandsDrained: proof.commandsDrained, ownedRunnerTerminated: proof.runnerTerminated)
            return true
        } catch { return false }
        }.value
    }
}

private struct AutomationExecutionFailure: Error {
    var summary: AttemptResult.Summary
    var dispatchUncertain: Bool
    var resourcesReleased: Bool
    var receipt: AutomationSegmentReceipt?
    var policyDenial: AutomationPolicyDenialReason?
}
