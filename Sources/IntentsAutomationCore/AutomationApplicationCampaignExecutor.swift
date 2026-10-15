#if os(macOS)
import Foundation

/// The production campaign adapter retains one native runner and its durable
/// target ownership; every attempt executes the same checked route contracts.
public struct AutomationApplicationCampaignExecutor: AutomationCampaignAttemptExecutor {
    private let runner: AutomationApplicationRunner
    private let prepared: AutomationPreparedApplication
    private let capabilities: CapabilityProfile
    private let allowBootAndInstall: Bool
    public init(runner: AutomationApplicationRunner, prepared: AutomationPreparedApplication,
                capabilities: CapabilityProfile, allowBootAndInstall: Bool) {
        self.runner = runner; self.prepared = prepared; self.capabilities = capabilities
        self.allowBootAndInstall = allowBootAndInstall
    }
    public func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String,
                        budget: AutomationCampaignBudget) async throws -> AutomationAttemptReport {
        try await execute(frozen: frozen, approval: approval, attemptID: attemptID, budget: budget, excludedEntityIDs: [])
    }
    public func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String,
                        budget: AutomationCampaignBudget, excludedEntityIDs: Set<String>) async throws -> AutomationAttemptReport {
        try frozen.validate()
        return try await runner.run(prepared: prepared, plan: frozen.plan, approval: approval, capabilities: capabilities,
            attemptID: attemptID, allowBootAndInstall: allowBootAndInstall, campaignBudget: budget, excludedEntityIDs: excludedEntityIDs)
    }
}
#endif
