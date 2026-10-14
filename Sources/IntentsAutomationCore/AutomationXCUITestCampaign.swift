#if os(macOS)
import Foundation
import Darwin
import IntentsAutomationUIHostContracts

/// One host test holds the target for the complete UI, intent and query workflow.
enum AutomationXCUITestCampaign {
    static func run(prepared: AutomationPreparedAppleHost, plan: AutomationCase,
                    approval: RunApproval, capabilities: CapabilityProfile, attemptID: String,
                    root: URL, developerDirectory: URL, leases: AutomationDeviceLeaseManager,
                    journal: AutomationJournal, artifacts: AutomationArtifactRegistry,
                    releaseVerifier: AutomationSimulatorReleaseVerifier?,
                    campaignBudget: AutomationCampaignBudget?,
                    releaseCampaignOnCompletion: Bool = true,
                    fixtureTracker: AutomationFreshFixtureTracker? = nil,
                    qualificationFence: AutomationFreshFixtureQualificationFence? = nil) async throws -> AutomationAttemptReport {
        try PlanValidator.validate(plan, approval: approval, capabilities: capabilities)
        let preflight = try AutomationXCUITestPlan.assemble(plan: plan, approval: approval,
            attemptID: attemptID, leaseGeneration: 1)
        do { try await reserveBudget(preflight, plan: plan, attemptID: attemptID, budget: campaignBudget) }
        catch {
            let released: Bool
            if releaseCampaignOnCompletion {
                released = (try? await leases.releaseCampaign(runID: approval.runID, target: plan.target)) != nil
            } else { released = true }
            return .init(attemptID: attemptID, result: AutomationAssessment.assess(plan: plan,
                attemptID: attemptID, subjectDispatched: false, subjectCompleted: false, observations: [],
                termination: error as? AutomationCampaignBudgetError == .exhausted("wall clock") ? .timedOut : .infrastructureFailed),
                receipts: [], resourcesReleased: released)
        }
        var excludedIDs = await fixtureTracker?.excludedEntityIDs() ?? []
        if let qualificationFence { excludedIDs.formUnion(await qualificationFence.excludedEntityIDs()) }
        let lease = try await leases.acquire(runID: approval.runID, target: plan.target, control: .ui)
        let scope = AutomationScope(runID: approval.runID, attemptID: attemptID,
                                    segmentID: "xcuitest", leaseGeneration: lease.generation)
        let operationID = "\(approval.runID):\(attemptID):xcuitest"
        let digest = try AutomationFrozenCase.planDigest(plan)
        let driver = AutomationXCUITestRouteDriver(prepared: prepared,
            root: root.appendingPathComponent("xcuitest"), artifacts: artifacts,
            developerDirectory: developerDirectory,
            willStart: {
                try await leases.validate(lease)
                try await campaignBudget?.available()
            }, didStart: { identity in
                var buffer = [CChar](repeating: 0, count: 4096)
                guard proc_pidpath(identity.pid, &buffer, UInt32(buffer.count)) > 0 else {
                    throw AutomationContractError.terminationUnverified
                }
                try await leases.recordRunner(.init(scope: scope, process: identity,
                    role: .nativeCommand, executablePath: String(cString: buffer)), lease: lease)
            }, willWritePayload: { reference in
                try await leases.recordPrivatePayload(reference, lease: lease)
            }, didCleanPayload: { reference in
                try await leases.retirePrivatePayload(reference, lease: lease)
            })
        var receipts: [AutomationSegmentReceipt] = []
        var termination: AttemptResult.Summary?
        var began = false, uncertainDispatch = false
        do {
            guard try await journal.begin(operationID: operationID, digest: digest) == nil else {
                throw AutomationContractError.ambiguousDispatch
            }
            try await leases.recordDispatch(.init(scope: scope, operationID: operationID,
                                                  payloadDigest: digest), lease: lease)
            began = true
            let remaining = try await campaignBudget?.remainingDuration()
            receipts = try await driver.execute(plan: plan, approval: approval,
                attemptID: attemptID, leaseGeneration: lease.generation,
                timeout: remaining, excludedEntityIDs: excludedIDs)
        } catch let failure as AutomationXCUITestFailure {
            receipts = failure.receipts
            termination = failure.reason
            uncertainDispatch = failure.subjectDispatchUncertain
        } catch {
            termination = error is CancellationError ? .cancelled : .infrastructureFailed
        }
        let subject = receipts.first { $0.segmentID == plan.execution.id && $0.route == plan.execution.kind }
        if subject?.dispatched == true {
            do {
                // The host checked the supplied excluded identities before subject dispatch.
                // Consume the same positively queried identities in the campaign ledger.
                try await fixtureTracker?.reserveBeforeSubject(receipts: receipts, plan: plan,
                    approval: approval, attemptID: attemptID)
                try await qualificationFence?.reserveBeforeSubject(receipts: receipts, plan: plan,
                    approval: approval, attemptID: attemptID)
            } catch { termination = .invalidFixture }
        }
        try await campaignBudget?.reserveResourceRelease(id: operationID)
        let proof = await Task.detached { await driver.release() }.value
        var released = proof.commandsDrained && proof.runnerTerminated && proof.privatePayloadCleaned
        if released, let releaseVerifier {
            released = await releaseVerifier.verifyReleased(target: plan.target,
                controllerBundleIDs: [prepared.hostBundleID])
        }
        do {
            if began, released {
                try await journal.complete(operationID: operationID, digest: digest, response: .bool(true))
            }
            try await leases.release(lease, commandsDrained: proof.commandsDrained,
                                     ownedRunnerTerminated: released)
            if releaseCampaignOnCompletion { try await leases.releaseCampaign(runID: approval.runID, target: plan.target) }
        } catch { released = false }

        let observations = receipts.filter { receipt in
            plan.observations.contains { $0.id == receipt.segmentID && $0.kind == receipt.route }
        }.flatMap(\.observations)
        if !released { termination = .unresolved }
        var result = AutomationAssessment.assess(plan: plan, attemptID: attemptID,
            subjectDispatched: subject?.dispatched == true, subjectCompleted: subject?.completed == true,
            observations: observations, receipts: receipts, runID: approval.runID, termination: termination)
        if let termination {
            result.summary = termination
            result.assessed = false
            result.evidenceComplete = false
        }
        result.subjectDispatchUncertain = uncertainDispatch || (subject?.dispatched == true && subject?.completed != true
            && termination != .assertionFailed && termination != .invalidFixture)
        return .init(attemptID: attemptID, result: result, receipts: receipts, resourcesReleased: released)
    }

    static func reserveBudget(_ uiPlan: UIHostPlan, plan: AutomationCase, attemptID: String,
                              budget: AutomationCampaignBudget?) async throws {
        guard let budget else { return }
        for segment in plan.setup + [plan.execution] + plan.observations + plan.cleanup {
            let steps = uiPlan.steps.filter { $0.segmentID == segment.id }
            let actions = steps.filter { [.launch, .tap, .typeText, .clearAndType, .swipe].contains($0.kind) }.count
            try await budget.reserveOperations(id: attemptID + ":xcuitest:" + segment.id,
                phase: segment.phase, count: steps.count, uiActions: actions)
        }
        try await budget.reserveControllerCall(id: attemptID + ":xcuitest")
    }
}
#endif
