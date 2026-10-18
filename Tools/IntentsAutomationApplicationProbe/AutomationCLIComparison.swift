#if os(macOS)
import Foundation
import IntentsAutomationCore

struct AutomationCLIComparisonResult: Encodable {
    let originalAttemptID: String
    let report: AutomationFixComparisonReport
    var outcome: AutomationFixComparisonOutcome { report.outcome }

    enum CodingKeys: String, CodingKey { case originalAttemptID, outcome, report }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(originalAttemptID, forKey: .originalAttemptID)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(report, forKey: .report)
    }
}

extension AutomationCLI {
    static func comparisonAttempts(_ text: String?) throws -> Int {
        guard let text else { return 3 }
        guard text.range(of: #"^[1-9][0-9]{0,2}$"#, options: .regularExpression) != nil,
              let value = Int(text), (1...100).contains(value) else {
            throw AutomationContractError.invalidPlan("Comparison attempts must be between 1 and 100")
        }
        return value
    }

    static func validateComparisonFailure(_ frozen: AutomationFrozenCase, original: AutomationAttemptReport) throws {
        try frozen.validate()
        try AutomationRecordedEvidence.validate(report: original, plan: frozen.plan)
        let result = original.result
        let segments = frozen.plan.setup + [frozen.plan.execution] + frozen.plan.observations + frozen.plan.cleanup
        guard frozen.plan.target.kind != .physical,
              result.summary == .assertionFailed, result.assessed, result.evidenceComplete,
              !result.failedObservations.isEmpty, original.resourcesReleased, !result.subjectDispatchUncertain,
              segments.allSatisfy({ $0.effects.isSubset(of: [.observe, .navigate, .fixtureWrite]) }) else {
            throw AutomationContractError.missingEvidence("Compare requires a saved, assessed, released failure with navigation or disposable fixture effects")
        }
        if segments.contains(where: { $0.effects.contains(.fixtureWrite) }) {
            guard frozen.plan.setupChecks?.isEmpty == false else {
                throw AutomationContractError.invalidPlan("Repeated fixture writes require frozen setup checks")
            }
        }
    }

    static func comparisonCandidate(baseline: AutomationFrozenCase, before: AutomationPreparedApplication,
                                    after: AutomationPreparedApplication) throws -> AutomationFrozenCase {
        guard before.host.app == baseline.plan.app, before.host.target == baseline.plan.target,
              before.host.target == after.host.target,
              before.source.sourceRoot == after.source.sourceRoot,
              before.host.app.sourceManifestDigest == (try before.source.digest),
              after.host.app.sourceManifestDigest == (try after.source.digest),
              before.host.app.sourceManifestDigest != after.host.app.sourceManifestDigest else {
            throw AutomationContractError.invalidPlan("Prepare changed source for the saved app and target, retaining its original build")
        }
        var verifiedBaseline = baseline.plan
        try attachPreparedEvidence(to: &verifiedBaseline, prepared: before)
        guard verifiedBaseline == baseline.plan else {
            throw AutomationContractError.missingEvidence("Saved failure must retain its exact prepared build evidence")
        }
        return try AutomationFixContract.candidate(from: baseline, prepared: after)
    }

    static func comparisonApproval(frozen: AutomationFrozenCase, runID: String) throws -> RunApproval {
        let segments = frozen.plan.setup + [frozen.plan.execution] + frozen.plan.observations + frozen.plan.cleanup
        return try deriveExactRunApproval(.init(schemaVersion: 1, attemptID: runID,
            allowBootAndInstall: frozen.plan.target.kind == .simulator,
            disposable: segments.contains(where: { $0.effects.contains(.fixtureWrite) }), plan: frozen.plan))
    }

    static func comparisonLimits(plan: AutomationCase, attempts: Int, maximumActions: Int) -> AutomationCampaignLimits {
        var limits = AutomationCampaignLimits()
        limits.attempts = attempts
        func scaled(_ value: Int) -> Int { min(100_000, min(100_000, max(0, value)) * attempts) }
        // Navigation readbacks can reserve more operations than actual UI actions.
        let operations = scaled(max(plan.budget.subjectOperations, maximumActions * 3))
        limits.subjectOperations = operations; limits.setupOperations = operations
        limits.observerOperations = operations; limits.cleanupOperations = operations
        limits.uiActions = scaled(max(plan.budget.uiActions, maximumActions))
        limits.controllerCalls = scaled(plan.budget.controllerCalls)
        limits.wallClockSeconds = scaled(plan.budget.wallClockSeconds)
        return limits
    }

    static func compare(baselineSupport: URL, originalAttemptID: String, support: URL,
                        attempts: Int) async throws -> AutomationCLIComparisonResult {
        guard (1...100).contains(attempts) else { throw AutomationContractError.invalidIdentity }
        let (baseline, original) = try await savedAttempt(attemptID: originalAttemptID, supportRoot: baselineSupport)
        try validateComparisonFailure(baseline, original: original)
        let before = try AutomationPreparedApplicationRecord.load(app: baseline.plan.app, supportRoot: baselineSupport)
        try AutomationPreparedArtifactIntegrity.verify(before)
        let after = try loadPrepared(support)
        let candidate = try comparisonCandidate(baseline: baseline, before: before, after: after)
        let runID = UUID().uuidString
        let beforeApproval = try comparisonApproval(frozen: baseline, runID: runID + "-before")
        let afterApproval = try comparisonApproval(frozen: candidate, runID: runID + "-after")
        let beforeDeveloper = try before.selectedDeveloperDirectoryPath.map { URL(fileURLWithPath: $0) } ?? developerDirectory(nil)
        let afterDeveloper = try after.selectedDeveloperDirectoryPath.map { URL(fileURLWithPath: $0) } ?? developerDirectory(nil)
        let beforeRunner = try AutomationApplicationRunner(supportRoot: baselineSupport, developerDirectory: beforeDeveloper)
        let afterRunner = try AutomationApplicationRunner(supportRoot: support, developerDirectory: afterDeveloper)
        let beforeCapabilities = try await beforeRunner.capabilitiesForExecution(subject: .prepared(before), plan: baseline.plan,
            capabilities: AutomationPreparedCapabilities.base(before), approval: beforeApproval)
        let afterCapabilities = try await afterRunner.capabilitiesForExecution(subject: .prepared(after), plan: candidate.plan,
            capabilities: AutomationPreparedCapabilities.base(after), approval: afterApproval)
        let cases = try AutomationCaseStore(root: support.appendingPathComponent("Cases"))
        let report = try await AutomationFixComparison(cases: cases).run(baseline: baseline, candidate: candidate,
            attemptsPerBuild: attempts, beforeApproval: beforeApproval, afterApproval: afterApproval,
            beforeCapabilities: beforeCapabilities, afterCapabilities: afterCapabilities,
            limits: comparisonLimits(plan: baseline.plan, attempts: attempts,
                maximumActions: max(beforeApproval.maximumActions, afterApproval.maximumActions)),
            beforeExecutor: AutomationSubjectCampaignExecutor(runner: beforeRunner, subject: .prepared(before), capabilities: beforeCapabilities,
                allowBootAndInstall: baseline.plan.target.kind == .simulator),
            afterExecutor: AutomationSubjectCampaignExecutor(runner: afterRunner, subject: .prepared(after), capabilities: afterCapabilities,
                allowBootAndInstall: candidate.plan.target.kind == .simulator))
        try await AutomationFixComparisonArchive(caseStoreRoot: support.appendingPathComponent("Cases")).save(report)
        return .init(originalAttemptID: originalAttemptID, report: report)
    }
}
#endif
