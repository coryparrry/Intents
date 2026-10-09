#if os(macOS)
import Foundation

/// Retains the exact selected subject across campaign attempts without changing route qualification.
public struct AutomationSubjectCampaignExecutor: AutomationFreshFixtureAttemptExecutor {
    struct Invocation: Sendable {
        let subject: AutomationApplicationSubject
        let frozen: AutomationFrozenCase
        let approval: RunApproval
        let capabilities: CapabilityProfile
        let attemptID: String
        let budget: AutomationCampaignBudget
        let fixtureTracker: AutomationFreshFixtureTracker?
        let allowBootAndInstall: Bool
        let uiRuntime: AutomationUIRuntime?
    }
    private let subject: AutomationApplicationSubject
    private let capabilities: CapabilityProfile
    private let allowBootAndInstall: Bool
    private let uiRuntime: AutomationUIRuntime?
    private let run: @Sendable (Invocation) async throws -> AutomationAttemptReport
    public init(runner: AutomationApplicationRunner, subject: AutomationApplicationSubject, capabilities: CapabilityProfile,
                allowBootAndInstall: Bool = false, uiRuntime: AutomationUIRuntime? = nil) {
        self.init(subject: subject, capabilities: capabilities, allowBootAndInstall: allowBootAndInstall, uiRuntime: uiRuntime, run: { invocation in
            try await runner.run(subject: invocation.subject, plan: invocation.frozen.plan, approval: invocation.approval,
                capabilities: invocation.capabilities, attemptID: invocation.attemptID, allowBootAndInstall: invocation.allowBootAndInstall,
                campaignBudget: invocation.budget, uiRuntime: invocation.uiRuntime, fixtureTracker: invocation.fixtureTracker)
        })
    }
    init(subject: AutomationApplicationSubject, capabilities: CapabilityProfile, allowBootAndInstall: Bool = false,
         uiRuntime: AutomationUIRuntime? = nil, run: @escaping @Sendable (Invocation) async throws -> AutomationAttemptReport) {
        self.subject = subject; self.capabilities = capabilities; self.allowBootAndInstall = allowBootAndInstall
        self.uiRuntime = uiRuntime; self.run = run
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
        try frozen.validate(); try subject.validate(plan: frozen.plan)
        if subject.prepared == nil {
            let segments = frozen.plan.setup + [frozen.plan.execution] + frozen.plan.observations + frozen.plan.cleanup
            guard tracker == nil, segments.allSatisfy({ $0.effects.isSubset(of: [.observe, .navigate]) }) else {
                throw AutomationContractError.missingEvidence("Installed campaigns require a read-only workflow")
            }
        }
        guard subject.target.kind != .nativeMac || tracker == nil else {
            throw AutomationContractError.missingEvidence("Mac fresh-fixture campaigns require qualified setup and reset equivalence")
        }
        return try await run(.init(subject: subject, frozen: frozen, approval: approval, capabilities: capabilities, attemptID: attemptID,
            budget: budget, fixtureTracker: tracker, allowBootAndInstall: allowBootAndInstall, uiRuntime: uiRuntime))
    }
}
#endif
