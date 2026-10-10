import Foundation

/// Counts from fresh executions of one frozen case; imported records grant no authority.
public struct AutomationReproductionReport: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var frozen: AutomationFrozenCase
    public var runID: String
    public var requestedAttempts = 5
    public var originalFailure: AutomationAttemptReport
    public var signature: [String]
    public var attempts: [AutomationAttemptReport] = []
    public var interruption: AutomationSearchInterruption?
    public var matchingFailures = 0
    public var assessedPasses = 0
    public var otherFailures = 0
    public var unassessed = 0
    public var counters = ScopeCounters()
    public var usage = AutomationCampaignUsage()
    public var stopReason: String?
    public var complete: Bool { attempts.count == requestedAttempts && interruption == nil && stopReason == nil && attempts.allSatisfy { $0.resourcesReleased && !$0.result.subjectDispatchUncertain && $0.result.summary != .cancelled && $0.result.summary != .invalidFixture } }
    public var reproduced: Bool { complete && matchingFailures > 0 }
    public init(frozen: AutomationFrozenCase, runID: String, originalFailure: AutomationAttemptReport) {
        self.frozen = frozen; self.runID = runID; self.originalFailure = originalFailure
        signature = originalFailure.result.failedObservations.sorted()
    }
    mutating func record(_ attempt: AutomationAttemptReport) {
        attempts.append(attempt); counters.record(attempt.result)
        let result = attempt.result
        if !result.assessed || !result.evidenceComplete { unassessed += 1 }
        else if result.summary == .passed { assessedPasses += 1 }
        else if result.summary == .assertionFailed {
            if result.failedObservations.sorted() == signature { matchingFailures += 1 }
            else { otherFailures += 1 }
        } else { unassessed += 1 }
    }
    public func validate() throws {
        try frozen.validate()
        try AutomationRecordedEvidence.validate(report: originalFailure, plan: frozen.plan)
        guard originalFailure.result.summary == .assertionFailed, originalFailure.result.assessed, originalFailure.result.evidenceComplete,
              originalFailure.resourcesReleased, !originalFailure.result.subjectDispatchUncertain,
              signature == originalFailure.result.failedObservations.sorted() else { throw AutomationContractError.conflictingOperation }
        guard schemaVersion == 1, requestedAttempts == 5, attempts.count <= 5,
              AutomationUIFailureSearchRecord.identifier(runID), !signature.isEmpty,
              signature == Array(Set(signature)).sorted(),
              Set(signature).isSubset(of: Set(frozen.plan.requirements.map { $0.checkID ?? $0.observationID })),
              stopReason.map({ !$0.isEmpty && $0.utf16.count <= 4096 }) ?? true else { throw AutomationContractError.invalidIdentity }
        let ids = attempts.map(\.attemptID) + (interruption.map { [$0.attemptID] } ?? [])
        guard ids.allSatisfy(AutomationUIFailureSearchRecord.identifier), Set(ids).count == ids.count,
              !ids.contains(originalFailure.attemptID), ids.count <= 5 else { throw AutomationContractError.conflictingOperation }
        var computed = AutomationReproductionReport(frozen: frozen, runID: runID, originalFailure: originalFailure)
        let segments = frozen.plan.setup + [frozen.plan.execution] + frozen.plan.observations + frozen.plan.cleanup
        let mutating = !segments.allSatisfy { $0.effects.isSubset(of: [.observe, .navigate]) }
        var seenIDs = mutating ? try AutomationQualifiedFreshFixture.recordedIdentities(report: originalFailure, plan: frozen.plan) : Set<String>()
        for (index, attempt) in attempts.enumerated() {
            try AutomationRecordedEvidence.validate(report: attempt, plan: frozen.plan, expectedRunID: runID)
            if mutating && (attempt.result.subjectDispatched || attempt.result.subjectDispatchUncertain) {
                let identities = try AutomationQualifiedFreshFixture.recordedIdentities(report: attempt, plan: frozen.plan)
                guard seenIDs.isDisjoint(with: identities) else { throw AutomationFixtureFreshnessError.invalidFixture }
                seenIDs.formUnion(identities)
            }
            computed.record(attempt)
            if !attempt.resourcesReleased || attempt.result.subjectDispatchUncertain || attempt.result.summary == .cancelled || attempt.result.summary == .invalidFixture {
                guard index == attempts.count - 1, interruption == nil, stopReason != nil else { throw AutomationContractError.conflictingOperation }
            }
        }
        if let interrupted = interruption {
            guard interrupted.caseDigest == frozen.digest, interrupted.stage == .finalConfirmation,
                  !interrupted.reason.isEmpty, interrupted.reason.utf16.count <= 4096, stopReason != nil else {
                throw AutomationContractError.conflictingOperation
            }
            computed.counters.planned += 1
            if interrupted.dispatchMayHaveOccurred { computed.counters.unresolved += 1 }
            else { computed.counters.notRun += 1 }
        }
        let usageValues = [usage.attempts, usage.reservedSubjectOperations, usage.reservedSetupOperations, usage.reservedObserverOperations,
            usage.reservedCleanupOperations, usage.reservedUIActions, usage.controllerCalls, usage.reservedResourceReleaseOperations]
        guard usageValues.allSatisfy({ (0...100_000).contains($0) }), complete || stopReason != nil,
              matchingFailures == computed.matchingFailures, assessedPasses == computed.assessedPasses,
              otherFailures == computed.otherFailures, unassessed == computed.unassessed,
              counters == computed.counters, usage.attempts == ids.count,
              usage.appModelRequests == nil else { throw AutomationContractError.conflictingOperation }
    }
}

/// The source runner supplies canonical facts; Swift alone computes repetition counts.
public actor AutomationReproduction {
    private let cases: AutomationCaseStore
    private var running = false
    public init(cases: AutomationCaseStore) { self.cases = cases }
    public func run(frozen: AutomationFrozenCase, originalAttemptID: String, approval: RunApproval,
                    capabilities: CapabilityProfile = .init(), limits: AutomationCampaignLimits,
                    executor: any AutomationCampaignAttemptExecutor,
                    fixture: AutomationQualifiedFreshFixture? = nil) async throws -> AutomationReproductionReport {
        guard !running else { throw AutomationContractError.targetBusy }
        running = true; defer { running = false }
        try frozen.validate(); try limits.validate()
        let originalFailure = try await cases.loadAttempt(id: originalAttemptID, frozen: frozen)
        let signature = originalFailure.result.failedObservations.sorted()
        guard originalFailure.result.summary == .assertionFailed, originalFailure.result.assessed, originalFailure.result.evidenceComplete,
              originalFailure.resourcesReleased, !originalFailure.result.subjectDispatchUncertain else { throw AutomationContractError.missingEvidence("Select an assessed, released failure") }
        guard approval.approvedCaseDigest == frozen.digest, limits.attempts >= 5, !signature.isEmpty,
              signature == Array(Set(signature)).sorted(),
              Set(signature).isSubset(of: Set(frozen.plan.requirements.map { $0.checkID ?? $0.observationID })) else {
            throw AutomationContractError.invalidPlan("Reproduction requires five exact-case approved attempts and an existing failure signature")
        }
        try PlanValidator.validate(frozen.plan, approval: approval, capabilities: capabilities)
        let segments = frozen.plan.setup + [frozen.plan.execution] + frozen.plan.observations + frozen.plan.cleanup
        var tracker: AutomationFreshFixtureTracker?
        if !segments.allSatisfy({ $0.effects.isSubset(of: [.observe, .navigate]) }) {
            guard let fixture, executor is any AutomationFreshFixtureAttemptExecutor else {
                throw AutomationContractError.missingEvidence("Mutating reproduction requires a live qualified fresh fixture and guarded executor")
            }
            try fixture.validate(plan: frozen.plan, approval: approval)
            guard let originalRunID = originalFailure.receipts.first?.scope.runId else { throw AutomationContractError.missingEvidence("Original fixture scope is missing") }
            var originalApproval = approval; originalApproval.runID = originalRunID
            let setup = originalFailure.receipts.filter { receipt in frozen.plan.setup.contains(where: { $0.id == receipt.segmentID }) }
            let originalIDs = try fixture.identities(receipts: setup, plan: frozen.plan, approval: originalApproval, attemptID: originalFailure.attemptID)
            tracker = AutomationFreshFixtureTracker(fixture: fixture, ledger: .init(fixtures: [fixture], excludedHistoricalIDs: originalIDs))
        }
        _ = try await cases.freeze(frozen.plan)
        let budget = try AutomationCampaignBudget(limits: limits)
        var result = AutomationReproductionReport(frozen: frozen, runID: approval.runID, originalFailure: originalFailure)
        for _ in 0..<5 {
            let id = UUID().uuidString; var entered = false, reserved = false
            do {
                try Task.checkCancellation()
                try await budget.reserveAttempt(id: id); reserved = true
                entered = true
                let report: AutomationAttemptReport
                if let tracker, let fresh = executor as? any AutomationFreshFixtureAttemptExecutor {
                    report = try await fresh.execute(frozen: frozen, approval: approval, attemptID: id, budget: budget, fixtureTracker: tracker)
                    try await tracker.validate(report: report, plan: frozen.plan, approval: approval)
                } else { report = try await executor.execute(frozen: frozen, approval: approval, attemptID: id, budget: budget) }
                guard report.attemptID == id else { throw AutomationContractError.conflictingOperation }
                try AutomationRecordedEvidence.validate(report: report, plan: frozen.plan, expectedRunID: approval.runID)
                if let existing = try? await cases.loadAttempt(id: id, frozen: frozen) {
                    guard existing == report else { throw AutomationContractError.conflictingOperation }
                } else { try await cases.saveAttempt(report, for: frozen) }
                result.record(report)
                if report.result.summary == .cancelled { result.stopReason = "Cancelled"; break }
                if report.result.summary == .invalidFixture {
                    result.stopReason = "Fixture did not meet the frozen setup checks; reproduction stopped"; break
                }
                guard report.resourcesReleased, !report.result.subjectDispatchUncertain else {
                    result.stopReason = "Unresolved dispatch or release; reproduction stopped"; break
                }
            } catch {
                result.stopReason = error is CancellationError ? "Cancelled" : "Reproduction stopped before canonical evidence could be verified"
                if reserved {
                    result.interruption = .init(attemptID: id, caseDigest: frozen.digest, stage: .finalConfirmation,
                        dispatchMayHaveOccurred: entered, reason: result.stopReason!)
                    result.counters.planned += 1
                    if entered { result.counters.unresolved += 1 } else { result.counters.notRun += 1 }
                }
                break
            }
        }
        result.usage = await budget.snapshot()
        try result.validate()
        return result
    }
}
