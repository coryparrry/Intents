#if os(macOS)
import Foundation

/// Continues one drained host attempt. It cannot launch or repeat its subject.
enum AutomationXCUITestDurableObservations {
    struct Result: Sendable {
        var receipts: [AutomationSegmentReceipt] = []
        var resourcesReleased = true
        var termination: AttemptResult.Summary?
    }

    static func execute(plan: AutomationCase, approval: RunApproval, capabilities: CapabilityProfile,
                        attemptID: String, priorReceipts: [AutomationSegmentReceipt],
                        deadline: ContinuousClock.Instant, leases: AutomationDeviceLeaseManager,
                        artifacts: AutomationArtifactRegistry, journal: AutomationJournal,
                        campaignBudget: AutomationCampaignBudget?,
                        driver suppliedDriver: (any AutomationRouteDriver)? = nil) async throws -> Result {
        try PlanValidator.validate(plan, approval: approval, capabilities: capabilities)
        let suffix = try AutomationXCUITestPlan.durableObservationSuffix(plan: plan)
        guard !suffix.isEmpty else { return Result() }
        let hosted = plan.setup + [plan.execution] + Array(plan.observations.dropLast(suffix.count))
        guard priorReceipts.map(\.segmentID) == hosted.map(\.id),
              zip(priorReceipts, hosted).allSatisfy({ receipt, segment in
                  receipt.route == segment.kind && receipt.app == plan.app && receipt.target == plan.target &&
                      receipt.environmentID == plan.environmentID && receipt.scope.runId == approval.runID &&
                      receipt.scope.attemptId == attemptID && receipt.scope.segmentId == segment.id &&
                      receipt.scope.leaseGeneration > 0 && receipt.dispatched && receipt.completed
              }) else {
            throw AutomationContractError.missingEvidence("Independent storage read requires the complete drained host prefix")
        }
        let driver: any AutomationRouteDriver = suppliedDriver ?? AutomationDurableStateRouteDriver(
            underlying: StorageOnlyDriver(), approval: approval, leases: leases, artifacts: artifacts)
        let coordinator = try AutomationCoordinator(leases: leases, journal: journal, cleanupTimeout: .seconds(90),
            campaignDeadline: campaignBudget?.deadline, releaseCampaignOnCompletion: false)
        var result = Result()
        for segment in suffix {
            do {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw AutomationRPCError.timedOut }
                try await campaignBudget?.reserveOperations(id: attemptID + ":durable:" + segment.id,
                    phase: .observe, count: segment.hostProgram?.operations.count ?? 0)
                try await campaignBudget?.reserveResourceRelease(id: attemptID + ":durable:" + segment.id)
                let (receipt, released) = try await coordinator.executeIndependentObservation(plan: plan,
                    segment: segment, approval: approval, attemptID: attemptID,
                    priorReceipts: priorReceipts + result.receipts, deadline: deadline, driver: driver)
                result.receipts.append(receipt)
                if !released {
                    result.resourcesReleased = false; result.termination = .unresolved; break
                }
                if !receipt.completed { result.termination = .unresolved; break }
            } catch let failure as AutomationExecutionFailure {
                if let receipt = failure.receipt { result.receipts.append(receipt) }
                result.resourcesReleased = failure.resourcesReleased
                result.termination = failure.resourcesReleased ? failure.summary : .unresolved
                break
            } catch {
                if error as? AutomationContractError == .targetBusy {
                    result.resourcesReleased = false; result.termination = .unresolved; break
                }
                result.termination = error is CancellationError ? .cancelled
                    : error as? AutomationRPCError == .timedOut || error as? AutomationCampaignBudgetError == .exhausted("wall clock")
                        ? .timedOut : .infrastructureFailed
                break
            }
        }
        return result
    }

    private struct StorageOnlyDriver: AutomationRouteDriver {
        func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope,
                     lease: AutomationDeviceLeaseManager.Lease) async throws {
            throw AutomationContractError.invalidPlan("Independent observer cannot dispatch another host segment")
        }
        func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope,
                     lease: AutomationDeviceLeaseManager.Lease) async throws -> AutomationSegmentReceipt {
            throw AutomationContractError.invalidPlan("Independent observer cannot dispatch another host segment")
        }
        func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async -> AutomationReleaseProof {
            .init(commandsDrained: true, runnerTerminated: true)
        }
    }
}
#endif
