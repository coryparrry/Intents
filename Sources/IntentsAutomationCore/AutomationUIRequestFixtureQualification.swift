#if os(macOS)
import Foundation

extension AutomationApplicationRunner {
    /// Runs qualification through the owned route, not imported report/recipe JSON.
    public func qualifyUIRequestFixture(subject: AutomationApplicationSubject, frozen: AutomationFrozenCase,
        approval: RunApproval, capabilities: CapabilityProfile, budget: AutomationCampaignBudget,
        allowBootAndInstall: Bool,
        onAttempt: (@Sendable (AutomationAttemptReport) async -> Void)? = nil,
        onInterrupted: (@Sendable (String) async -> Void)? = nil) async throws -> AutomationQualifiedUIRequestFixture {
        try frozen.validate()
        let tracker = try AutomationUIRequestFixtureTracker(plan: frozen.plan, approval: approval)
        var reports: [AutomationAttemptReport] = []
        for _ in 0..<2 {
            let id = UUID().uuidString
            try await budget.reserveAttempt(id: id)
            let report: AutomationAttemptReport
            do {
                report = try await run(subject: subject, plan: frozen.plan, approval: approval, capabilities: capabilities,
                    attemptID: id, allowBootAndInstall: allowBootAndInstall, campaignBudget: budget,
                    uiRequestFixtureTracker: tracker)
            } catch {
                if let retained = try await retainedAttempt(attemptID: id, plan: frozen.plan, runID: approval.runID) { await onAttempt?(retained) }
                else { await onInterrupted?(id) }
                throw error
            }
            await onAttempt?(report)
            try await tracker.validate(report: report, plan: frozen.plan, approval: approval)
            guard report.resourcesReleased, report.result.subjectCompleted, !report.result.subjectDispatchUncertain,
                  [.passed, .assertionFailed, .executedUnassessed].contains(report.result.summary) else {
                throw AutomationContractError.missingEvidence("Fresh UI session qualification did not finish; inspect retained attempts before repeating")
            }
            reports.append(report)
        }
        return try .init(plan: frozen.plan, approval: approval, tracker: tracker, attempts: reports)
    }
}
#endif
