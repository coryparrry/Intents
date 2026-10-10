#if os(macOS)
import Foundation
import IntentsAutomationCore

/// The runner surface fresh-fixture qualification depends on.
protocol AutomationFreshFixtureQualifyingRunner: Sendable {
    func capabilitiesForExecution(subject: AutomationApplicationSubject, plan: AutomationCase,
                                  capabilities: CapabilityProfile) async throws -> CapabilityProfile
    func run(prepared: AutomationPreparedApplication, plan: AutomationCase, approval: RunApproval,
             capabilities: CapabilityProfile, attemptID: String, allowBootAndInstall: Bool, campaignBudget: AutomationCampaignBudget?,
             uiRuntime: AutomationUIRuntime?, fixtureTracker: AutomationFreshFixtureTracker?, qualifyingFreshBindings: [AutomationFreshFixtureBinding]?) async throws -> AutomationAttemptReport
    func validateFreshFixtureAttempt(bindings: [AutomationFreshFixtureBinding]) async throws
    func qualifyFreshFixture(bindings: [AutomationFreshFixtureBinding]) async throws -> AutomationQualifiedFreshFixture
}
extension AutomationApplicationRunner: AutomationFreshFixtureQualifyingRunner {}

enum AutomationNativeFreshFixtures {
    static func capabilities(_ prepared: AutomationPreparedApplication) -> CapabilityProfile {
        var value = AutomationEntityQuery.capabilities(prepared)
        value.records["apple.intent.invoke"] = .init(state: .available,
            reason: "Associated Apple host; registration is checked by invocation", probeVersion: "host-v2", evidence: [prepared.host.xctestrunDigest])
        return value
    }
    /// Requalify through actual execution in this runner. Saved reports can only
    /// exclude historical IDs; they cannot restore this non-Codable authority.
    static func qualify(frozen: AutomationFrozenCase, prepared: AutomationPreparedApplication, approval: RunApproval, capabilities: CapabilityProfile,
                        runner: some AutomationFreshFixtureQualifyingRunner, runtime: AutomationUIRuntime?, installApproved: Bool) async throws -> AutomationQualifiedFreshFixture {
        let bindings = try AutomationFreshEntityPlanner.bindings(plan: frozen.plan)
        let capabilities = try await runner.capabilitiesForExecution(subject: .prepared(prepared), plan: frozen.plan,
            capabilities: capabilities)
        try AutomationQualifiedFreshFixture.validateProposal(bindings: bindings, plan: frozen.plan, approval: approval, capabilities: capabilities)
        var limits = AutomationCampaignLimits.firstCampaign
        limits.attempts = 2; limits.subjectOperations = 2; limits.uiActions = 60; limits.controllerCalls = 24; limits.wallClockSeconds = 1200
        let budget = try AutomationCampaignBudget(limits: limits)
        for _ in 0..<2 {
            try Task.checkCancellation()
            let id = UUID().uuidString
            try await budget.reserveAttempt(id: id)
            let report = try await runner.run(prepared: prepared, plan: frozen.plan, approval: approval, capabilities: capabilities,
                attemptID: id, allowBootAndInstall: installApproved, campaignBudget: budget, uiRuntime: runtime, fixtureTracker: nil, qualifyingFreshBindings: bindings)
            guard report.resourcesReleased, report.result.subjectCompleted, !report.result.subjectDispatchUncertain,
                  [.passed, .assertionFailed, .executedUnassessed].contains(report.result.summary) else {
                throw AutomationContractError.missingEvidence("Fresh fixture qualification did not complete and release; inspect its saved attempt before continuing")
            }
            try await runner.validateFreshFixtureAttempt(bindings: bindings)
        }
        return try await runner.qualifyFreshFixture(bindings: bindings)
    }
}
#endif

#if os(macOS)
import Foundation
import IntentsAutomationCore

extension AppAutomationStore {
    func retainLearnedSetup(_ attempt: AutomationCapturedSetupAttempt) {
        learnedSetupAttempts.append(attempt)
        if learnedSetupAttempts.count > 2 { learnedSetupAttempts.removeFirst() }
        learnedSetupRecipe = try? AutomationQualifiedNavigationSetupRecipe(attempts: learnedSetupAttempts)
    }
}
#endif
