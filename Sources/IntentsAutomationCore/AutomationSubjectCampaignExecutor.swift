#if os(macOS)
import Foundation

/// Retains the exact selected subject across campaign attempts without changing route qualification.
public struct AutomationSubjectCampaignExecutor: AutomationCampaignAttemptExecutor {
    struct Invocation: Sendable {
        let subject: AutomationApplicationSubject
        let frozen: AutomationFrozenCase
        let approval: RunApproval
        let capabilities: CapabilityProfile
        let attemptID: String
        let budget: AutomationCampaignBudget
        let allowBootAndInstall: Bool
        let excludedEntityIDs: Set<String>
    }
    private let subject: AutomationApplicationSubject
    private let capabilities: CapabilityProfile
    private let allowBootAndInstall: Bool
    private let run: @Sendable (Invocation) async throws -> AutomationAttemptReport
    public init(runner: AutomationApplicationRunner, subject: AutomationApplicationSubject, capabilities: CapabilityProfile,
                allowBootAndInstall: Bool = false) {
        self.init(subject: subject, capabilities: capabilities, allowBootAndInstall: allowBootAndInstall, run: { invocation in
            try await runner.run(subject: invocation.subject, plan: invocation.frozen.plan, approval: invocation.approval,
                capabilities: invocation.capabilities, attemptID: invocation.attemptID, allowBootAndInstall: invocation.allowBootAndInstall,
                campaignBudget: invocation.budget, excludedEntityIDs: invocation.excludedEntityIDs)
        })
    }
    init(subject: AutomationApplicationSubject, capabilities: CapabilityProfile, allowBootAndInstall: Bool = false,
         run: @escaping @Sendable (Invocation) async throws -> AutomationAttemptReport) {
        self.subject = subject; self.capabilities = capabilities; self.allowBootAndInstall = allowBootAndInstall
        self.run = run
    }
    public func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String,
                        budget: AutomationCampaignBudget) async throws -> AutomationAttemptReport {
        try await execute(frozen: frozen, approval: approval, attemptID: attemptID, budget: budget, excludedEntityIDs: [])
    }
    public func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String,
                        budget: AutomationCampaignBudget, excludedEntityIDs: Set<String>) async throws -> AutomationAttemptReport {
        try frozen.validate(); try subject.validate(plan: frozen.plan)
        if subject.prepared == nil {
            let segments = frozen.plan.setup + [frozen.plan.execution] + frozen.plan.observations + frozen.plan.cleanup
            guard segments.allSatisfy({ $0.effects.isSubset(of: [.observe, .navigate]) }) else {
                throw AutomationContractError.missingEvidence("Installed campaigns require a read-only workflow")
            }
        }
        return try await run(.init(subject: subject, frozen: frozen, approval: approval, capabilities: capabilities, attemptID: attemptID,
            budget: budget, allowBootAndInstall: allowBootAndInstall, excludedEntityIDs: excludedEntityIDs))
    }
}
#endif
