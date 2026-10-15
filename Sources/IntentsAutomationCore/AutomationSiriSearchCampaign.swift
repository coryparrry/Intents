#if os(macOS)
import Foundation

/// Replays each reviewed phrase with the frozen reset and independent state observations.
public struct AutomationSiriCampaignExecutor: AutomationCampaignAttemptExecutor {
    public let runner: AutomationApplicationRunner
    public let prepared: AutomationPreparedApplication
    public let capabilities: CapabilityProfile
    public init(runner: AutomationApplicationRunner, prepared: AutomationPreparedApplication, capabilities: CapabilityProfile) {
        self.runner = runner; self.prepared = prepared; self.capabilities = capabilities
    }
    public func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String,
                        budget: AutomationCampaignBudget) async throws -> AutomationAttemptReport {
        try await runner.run(prepared: prepared, plan: frozen.plan, approval: approval, capabilities: capabilities,
            attemptID: attemptID, allowBootAndInstall: true, campaignBudget: budget)
    }
}

public enum AutomationSiriSearchCampaign {
    public static func run(baseline: AutomationFrozenCase, mutations: [AutomationMutationCase], approval: AutomationSearchApproval,
                           prepared: AutomationPreparedApplication, capabilities: CapabilityProfile,
                           runner: AutomationApplicationRunner, cases: AutomationCaseStore) async throws -> AutomationFailureSearchReport {
        try baseline.validate()
        try AutomationSiriResetPlan.validateStructure(plan: baseline.plan, approval: approval.run)
        guard approval.run.app == prepared.host.app, approval.run.target == prepared.host.target,
              mutations.allSatisfy({ $0.subjectPhraseSlot == .siriRecognizedText }) else {
            throw AutomationContractError.invalidIdentity
        }
        let resolved = try AutomationPreparedCapabilities.resolving(capabilities, prepared: prepared)
        return try await AutomationFailureSearch(cases: cases).run(baseline: baseline, mutations: mutations,
            approval: approval, capabilities: resolved,
            executor: AutomationSiriCampaignExecutor(runner: runner, prepared: prepared, capabilities: resolved))
    }
}
#endif
