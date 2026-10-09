#if os(macOS)
import Foundation

/// The production campaign adapter retains one native runner and its durable
/// target ownership; every attempt executes the same checked route contracts.
public struct AutomationApplicationCampaignExecutor: AutomationFreshFixtureAttemptExecutor {
    private let runner: AutomationApplicationRunner
    private let prepared: AutomationPreparedApplication
    private let capabilities: CapabilityProfile
    private let allowBootAndInstall: Bool
    private let uiRuntime: AutomationUIRuntime?
    public init(runner: AutomationApplicationRunner, prepared: AutomationPreparedApplication,
                capabilities: CapabilityProfile, allowBootAndInstall: Bool, uiRuntime: AutomationUIRuntime? = nil) {
        self.runner = runner; self.prepared = prepared; self.capabilities = capabilities
        self.allowBootAndInstall = allowBootAndInstall; self.uiRuntime = uiRuntime
    }
    public func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String,
                        budget: AutomationCampaignBudget) async throws -> AutomationAttemptReport {
        try await execute(frozen: frozen, approval: approval, attemptID: attemptID, budget: budget, tracker: nil)
    }
    public func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String,
                        budget: AutomationCampaignBudget, fixtureTracker: AutomationFreshFixtureTracker) async throws -> AutomationAttemptReport {
        try await execute(frozen: frozen, approval: approval, attemptID: attemptID, budget: budget, tracker: fixtureTracker)
    }
    private func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String,
                         budget: AutomationCampaignBudget, tracker: AutomationFreshFixtureTracker?) async throws -> AutomationAttemptReport {
        try frozen.validate()
        return try await runner.run(prepared: prepared, plan: frozen.plan, approval: approval, capabilities: capabilities,
            attemptID: attemptID, allowBootAndInstall: allowBootAndInstall, campaignBudget: budget, uiRuntime: uiRuntime, fixtureTracker: tracker)
    }
}
#endif
