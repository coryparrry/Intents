import Foundation

public struct AutomationFixComparisonReport: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var contractDigest: String
    public var baseline: AutomationFrozenCase
    public var candidate: AutomationFrozenCase
    public var requestedAttemptsPerBuild: Int
    public var beforeRunID = ""
    public var afterRunID = ""
    public var before: [AutomationAttemptReport] = []
    public var after: [AutomationAttemptReport] = []
    public var beforeCounters = ScopeCounters()
    public var afterCounters = ScopeCounters()
    public var beforeUsage = AutomationCampaignUsage()
    public var afterUsage = AutomationCampaignUsage()
    public var stopReason: String?
    public var interruption: AutomationSearchInterruption?
    /// Build effects are not statistically guaranteed, and unobserved model/provider changes remain unknown.
    public var environmentQualificationComplete = false
    public var comparisonScope = "Same frozen declared contract and environment; observed counts, not guaranteed reliability"
}
public enum AutomationFixContract {
#if os(macOS)
    public static func candidate(from baseline: AutomationFrozenCase, prepared: AutomationPreparedApplication) throws -> AutomationFrozenCase {
        guard let before = baseline.plan.preparedMacBuildArtifacts, prepared.host.target == baseline.plan.target else {
            throw AutomationContractError.missingEvidence("Review a versioned prepared Mac case before comparing rebuilt associated hosts")
        }
        let artifacts = try AutomationPreparedMacBuildArtifacts(prepared: prepared)
        guard before.hostTemplateDigest == artifacts.hostTemplateDigest, before.catalogSurfaceDigest == artifacts.catalogSurfaceDigest else {
            throw AutomationContractError.invalidPlan("Fix comparison changed the associated-host template or declared catalog surface")
        }
        let unchanged = try candidate(from: baseline, app: prepared.host.app)
        var plan = unchanged.plan; plan.preparedMacBuildArtifacts = artifacts
        let candidate = try AutomationFrozenCase(plan: plan)
        try validate(baseline: baseline, candidate: candidate); return candidate
    }
#endif
    public static func candidate(from baseline: AutomationFrozenCase, app: AppIdentity) throws -> AutomationFrozenCase {
        try baseline.validate()
        guard baseline.plan.target.kind != .physical, baseline.plan.app.productDigest != nil,
              app.logicalID == baseline.plan.app.logicalID, app.bundleID == baseline.plan.app.bundleID,
              app.platform == baseline.plan.app.platform, app.productDigest != nil,
              app.architecture == baseline.plan.app.architecture, app.configuration == baseline.plan.app.configuration,
              app.owningModule == baseline.plan.app.owningModule,
              app.productDigest != baseline.plan.app.productDigest,
              (app.productDigestVersion ?? 1) == (baseline.plan.app.productDigestVersion ?? 1) else { throw AutomationContractError.invalidPlan("Select a separately built changed app") }
        var plan = baseline.plan; plan.app = app; plan.revision += 1
        let candidate = try AutomationFrozenCase(plan: plan)
        try validate(baseline: baseline, candidate: candidate); return candidate
    }
    public static func validate(baseline: AutomationFrozenCase, candidate: AutomationFrozenCase) throws {
        try baseline.validate(); try candidate.validate()
        guard baseline.plan.target.kind != .physical, candidate.plan.target.kind != .physical,
              baseline.plan.app.productDigest != nil, candidate.plan.app.productDigest != nil,
              baseline.contractDigest == candidate.contractDigest, baseline.oracleDigest == candidate.oracleDigest,
              baseline.plan.id == candidate.plan.id, baseline.plan.revision != candidate.plan.revision,
              baseline.plan.app.productDigest != candidate.plan.app.productDigest,
              (baseline.plan.app.productDigestVersion ?? 1) == (candidate.plan.app.productDigestVersion ?? 1) else { throw AutomationContractError.invalidPlan("Fix comparison changed the frozen business or harness contract") }
    }
}
public actor AutomationFixComparison {
    private let cases: AutomationCaseStore
    private var running = false
    public init(cases: AutomationCaseStore) { self.cases = cases }
    public func run(baseline: AutomationFrozenCase, candidate: AutomationFrozenCase, attemptsPerBuild: Int = 30,
                    beforeApproval: RunApproval, afterApproval: RunApproval, beforeCapabilities: CapabilityProfile = .init(), afterCapabilities: CapabilityProfile = .init(), limits: AutomationCampaignLimits,
                    beforeExecutor: any AutomationCampaignAttemptExecutor, afterExecutor: any AutomationCampaignAttemptExecutor,
                    beforeFixture: AutomationQualifiedFreshFixture? = nil, afterFixture: AutomationQualifiedFreshFixture? = nil) async throws -> AutomationFixComparisonReport {
        guard !running else { throw AutomationContractError.targetBusy }
        try AutomationFixContract.validate(baseline: baseline, candidate: candidate); try limits.validate()
        guard attemptsPerBuild > 0, attemptsPerBuild <= 100, attemptsPerBuild <= limits.attempts,
              beforeApproval.approvedCaseDigest == baseline.digest, afterApproval.approvedCaseDigest == candidate.digest,
              beforeApproval.runID != afterApproval.runID else { throw AutomationContractError.invalidPlan("Both fresh comparison populations require separate exact-case approval and budgets") }
        try PlanValidator.validate(baseline.plan, approval: beforeApproval, capabilities: beforeCapabilities)
        try PlanValidator.validate(candidate.plan, approval: afterApproval, capabilities: afterCapabilities)
        let segments = baseline.plan.setup + [baseline.plan.execution] + baseline.plan.observations + baseline.plan.cleanup
        let mutating = !segments.allSatisfy({ $0.effects.isSubset(of: [.observe, .navigate]) })
        var beforeTracker: AutomationFreshFixtureTracker?, afterTracker: AutomationFreshFixtureTracker?
        if mutating {
            guard let beforeFixture, let afterFixture else {
                throw AutomationContractError.missingEvidence("Repeated mutating comparison requires separately qualified fresh fixtures for both builds")
            }
            try beforeFixture.validate(plan: baseline.plan, approval: beforeApproval)
            try afterFixture.validate(plan: candidate.plan, approval: afterApproval)
            guard beforeFixture.context.uiRuntimeManifestDigest == afterFixture.context.uiRuntimeManifestDigest else {
                throw AutomationContractError.missingEvidence("Changed UI harness requires qualifying both builds under the same runtime")
            }
            guard beforeExecutor is any AutomationFreshFixtureAttemptExecutor, afterExecutor is any AutomationFreshFixtureAttemptExecutor else {
                throw AutomationContractError.missingEvidence("Mutating comparison requires pre-dispatch fresh-fixture executors")
            }
            let ledger = AutomationFixtureIdentityLedger(fixtures: [beforeFixture, afterFixture])
            beforeTracker = AutomationFreshFixtureTracker(fixture: beforeFixture, ledger: ledger)
            afterTracker = AutomationFreshFixtureTracker(fixture: afterFixture, ledger: ledger)
        }
        running = true; defer { running = false }
        _ = try await cases.freeze(baseline.plan); _ = try await cases.freeze(candidate.plan)
        let beforeBudget = try AutomationCampaignBudget(limits: limits), afterBudget = try AutomationCampaignBudget(limits: limits)
        var result = AutomationFixComparisonReport(contractDigest: baseline.contractDigest, baseline: baseline, candidate: candidate, requestedAttemptsPerBuild: attemptsPerBuild)
        result.beforeRunID = beforeApproval.runID; result.afterRunID = afterApproval.runID
        for (frozen, approval, budget, executor, tracker, isBefore) in [(baseline, beforeApproval, beforeBudget, beforeExecutor, beforeTracker, true), (candidate, afterApproval, afterBudget, afterExecutor, afterTracker, false)] {
            for _ in 0..<attemptsPerBuild {
                let id = UUID().uuidString; var enteredExecutor = false, reserved = false
                do {
                    try Task.checkCancellation()
                    try await budget.reserveAttempt(id: id); reserved = true
                    enteredExecutor = true
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
                    if isBefore { result.before.append(report); result.beforeCounters.record(report.result) }
                    else { result.after.append(report); result.afterCounters.record(report.result) }
                    if report.result.summary == .cancelled { result.stopReason = "Cancelled"; break }
                    if report.result.summary == .invalidFixture { result.stopReason = "Fixture did not meet the frozen setup checks; comparison stopped"; break }
                    guard report.resourcesReleased, !report.result.subjectDispatchUncertain else {
                        result.stopReason = "Unresolved dispatch or release; comparison stopped"; break
                    }
                } catch {
                    result.stopReason = error is CancellationError ? "Cancelled" : "Comparison stopped before canonical evidence could be verified"
                    if reserved {
                        result.interruption = .init(attemptID: id, caseDigest: frozen.digest, stage: .baseline, dispatchMayHaveOccurred: enteredExecutor, reason: result.stopReason!)
                        if isBefore { result.beforeCounters.planned += 1; if enteredExecutor { result.beforeCounters.unresolved += 1 } else { result.beforeCounters.notRun += 1 } }
                        else { result.afterCounters.planned += 1; if enteredExecutor { result.afterCounters.unresolved += 1 } else { result.afterCounters.notRun += 1 } }
                    }
                    break
                }
            }
            if result.stopReason != nil { break }
        }
        result.beforeUsage = await beforeBudget.snapshot(); result.afterUsage = await afterBudget.snapshot()
        try result.validate()
        return result
    }
}
