#if os(macOS)
import Foundation

/// Read-only installed-app campaigns use the same native owner and budgets.
/// This adapter cannot claim live fresh-fixture qualification for repeated writes.
public struct AutomationInstalledUICampaignExecutor: AutomationCampaignAttemptExecutor {
    private let runner: AutomationApplicationRunner
    private let installed: AutomationInstalledUIApplication
    private let runtime: AutomationUIRuntime
    private let allowBootAndInstall: Bool
    public init(runner: AutomationApplicationRunner, installed: AutomationInstalledUIApplication,
                runtime: AutomationUIRuntime, allowBootAndInstall: Bool) {
        self.runner = runner; self.installed = installed; self.runtime = runtime; self.allowBootAndInstall = allowBootAndInstall
    }
    public func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String,
                        budget: AutomationCampaignBudget) async throws -> AutomationAttemptReport {
        try frozen.validate()
        let segments = frozen.plan.setup + [frozen.plan.execution] + frozen.plan.observations + frozen.plan.cleanup
        guard segments.allSatisfy({ $0.effects.isSubset(of: [.observe, .navigate]) }) else {
            throw AutomationContractError.missingEvidence("Installed UI campaigns require a read-only workflow")
        }
        return try await runner.run(subject: .installedUI(installed), plan: frozen.plan, approval: approval, capabilities: .init(),
            attemptID: attemptID, allowBootAndInstall: allowBootAndInstall, campaignBudget: budget, uiRuntime: runtime)
    }
}
#endif
