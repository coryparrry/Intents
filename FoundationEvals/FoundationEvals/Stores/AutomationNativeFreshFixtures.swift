#if os(macOS)
import Foundation
import IntentsAutomationCore

/// The runner surface fresh-fixture qualification depends on.
protocol AutomationFreshFixtureQualifyingRunner: Sendable {
    func capabilitiesForExecution(subject: AutomationApplicationSubject, plan: AutomationCase,
                                  capabilities: CapabilityProfile) async throws -> CapabilityProfile
    func run(prepared: AutomationPreparedApplication, plan: AutomationCase, approval: RunApproval,
             capabilities: CapabilityProfile, attemptID: String, allowBootAndInstall: Bool, campaignBudget: AutomationCampaignBudget?,
             fixtureTracker: AutomationFreshFixtureTracker?, qualifyingFreshBindings: [AutomationFreshFixtureBinding]?) async throws -> AutomationAttemptReport
    func capabilitiesForExecution(subject: AutomationApplicationSubject, plan: AutomationCase,
                                  capabilities: CapabilityProfile, approval: RunApproval) async throws -> CapabilityProfile
    func retainedAttempt(attemptID: String, plan: AutomationCase, runID: String) async throws -> AutomationAttemptReport?
    func validateFreshFixtureAttempt(bindings: [AutomationFreshFixtureBinding]) async throws
    func qualifyFreshFixture(bindings: [AutomationFreshFixtureBinding]) async throws -> AutomationQualifiedFreshFixture
}
extension AutomationFreshFixtureQualifyingRunner {
    func capabilitiesForExecution(subject: AutomationApplicationSubject, plan: AutomationCase,
                                  capabilities: CapabilityProfile, approval: RunApproval) async throws -> CapabilityProfile {
        try await capabilitiesForExecution(subject: subject, plan: plan, capabilities: capabilities)
    }
    func retainedAttempt(attemptID: String, plan: AutomationCase, runID: String) async throws -> AutomationAttemptReport? { nil }
}
extension AutomationApplicationRunner: AutomationFreshFixtureQualifyingRunner {
    func capabilitiesForExecution(subject: AutomationApplicationSubject, plan: AutomationCase,
                                  capabilities: CapabilityProfile) async throws -> CapabilityProfile {
        try await capabilitiesForExecution(subject: subject, plan: plan, capabilities: capabilities, approval: nil)
    }
    func capabilitiesForExecution(subject: AutomationApplicationSubject, plan: AutomationCase,
                                  capabilities: CapabilityProfile, approval: RunApproval) async throws -> CapabilityProfile {
        try await capabilitiesForExecution(subject: subject, plan: plan, capabilities: capabilities, approval: Optional(approval))
    }
    func run(prepared: AutomationPreparedApplication, plan: AutomationCase, approval: RunApproval,
             capabilities: CapabilityProfile, attemptID: String, allowBootAndInstall: Bool,
             campaignBudget: AutomationCampaignBudget?, fixtureTracker: AutomationFreshFixtureTracker?,
             qualifyingFreshBindings: [AutomationFreshFixtureBinding]?) async throws -> AutomationAttemptReport {
        try await run(prepared: prepared, plan: plan, approval: approval, capabilities: capabilities,
            attemptID: attemptID, allowBootAndInstall: allowBootAndInstall, campaignBudget: campaignBudget,
            fixtureTracker: fixtureTracker, qualifyingFreshBindings: qualifyingFreshBindings, uiRequestFixtureTracker: nil)
    }
}

enum AutomationNativeFreshFixtures {
    static func capabilities(_ prepared: AutomationPreparedApplication) -> CapabilityProfile {
        AutomationPreparedCapabilities.base(prepared)
    }
    /// Requalify through actual execution in this runner. Saved reports can only
    /// exclude historical IDs; they cannot restore this non-Codable authority.
    static func qualify(frozen: AutomationFrozenCase, prepared: AutomationPreparedApplication, approval: RunApproval, capabilities: CapabilityProfile,
                        runner: some AutomationFreshFixtureQualifyingRunner, installApproved: Bool, campaignBudget: AutomationCampaignBudget? = nil,
                        onAttempt: (@Sendable (AutomationAttemptReport) async -> Void)? = nil,
                        onInterrupted: (@Sendable (String) async -> Void)? = nil) async throws -> AutomationQualifiedFreshFixture {
        let bindings = try AutomationFreshEntityPlanner.bindings(plan: frozen.plan)
        let capabilities = try await runner.capabilitiesForExecution(subject: .prepared(prepared), plan: frozen.plan,
            capabilities: capabilities, approval: approval)
        try AutomationQualifiedFreshFixture.validateProposal(bindings: bindings, plan: frozen.plan, approval: approval, capabilities: capabilities)
        var limits = AutomationCampaignLimits.firstCampaign
        limits.attempts = 2; limits.subjectOperations = 2; limits.uiActions = 60; limits.controllerCalls = 24; limits.wallClockSeconds = 1200
        let budget = try campaignBudget ?? AutomationCampaignBudget(limits: limits)
        for _ in 0..<2 {
            try Task.checkCancellation()
            let id = UUID().uuidString
            try await budget.reserveAttempt(id: id)
            let report: AutomationAttemptReport
            do { report = try await runner.run(prepared: prepared, plan: frozen.plan, approval: approval, capabilities: capabilities,
                attemptID: id, allowBootAndInstall: installApproved, campaignBudget: budget, fixtureTracker: nil, qualifyingFreshBindings: bindings)
            } catch {
                if let retained = try await runner.retainedAttempt(attemptID: id, plan: frozen.plan, runID: approval.runID) { await onAttempt?(retained) }
                else { await onInterrupted?(id) }
                throw error
            }
            await onAttempt?(report)
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
        if let learnedSetupRecipe { persistLearnedSetup(learnedSetupRecipe) }
    }
    func persistLearnedSetup(_ recipe: AutomationQualifiedNavigationSetupRecipe) {
        do {
            let proposal = try recipe.savedProposal()
            try AutomationNavigationSetupRecipeStore(supportRoot: support).save(proposal)
            savedLearnedSetupRecipe = proposal
            learnedSetupPersistenceError = nil
        } catch {
            // Keep the live qualification and original execution evidence intact.
            learnedSetupPersistenceError = "Setup recipe could not be saved: \(error.localizedDescription)"
        }
    }
    func reloadLearnedSetup(context: AutomationRecipeContext) {
        savedLearnedSetupRecipe = nil
        if (learnedSetupRecipe?.context ?? learnedSetupAttempts.first?.context) != context {
            learnedSetupRecipe = nil
            learnedSetupAttempts = []
        }
        do {
            savedLearnedSetupRecipe = try AutomationNavigationSetupRecipeStore(supportRoot: support).read(context: context)
            learnedSetupPersistenceError = nil
        } catch {
            learnedSetupPersistenceError = "Saved setup recipe is unavailable: \(error.localizedDescription)"
        }
    }
    func reloadSelectedLearnedSetup() {
        guard let prepared, prepared.host.app.logicalID == candidateID,
              prepared.host.app.configuration == configuration, prepared.generatedHost.configuration == configuration,
              prepared.host.target == sourcePreparationTarget else {
            clearLearnedSetupSelection()
            return
        }
        do {
            let environment: String, runtimeDigest: String?
            switch prepared.host.target.kind {
            case .simulator:
                guard preparedUISelectionMatches else { throw AutomationContractError.invalidIdentity }
                environment = "selected-simulator:" + prepared.host.target.id
                runtimeDigest = nil
            default:
                clearLearnedSetupSelection()
                return
            }
            let context = AutomationRecipeContext(app: prepared.host.app, target: prepared.host.target, environmentID: environment,
                catalogDigest: try AutomationRecipeContext.catalogDigest(prepared.catalog), hostDigest: prepared.host.hostProductDigest,
                localeIdentifier: Locale.current.identifier, uiRuntimeManifestDigest: runtimeDigest)
            reloadLearnedSetup(context: context)
        } catch {
            clearLearnedSetupSelection()
            learnedSetupPersistenceError = "Saved setup recipe is unavailable for this app/runtime: \(error.localizedDescription)"
        }
    }
    private func clearLearnedSetupSelection() {
        savedLearnedSetupRecipe = nil
        learnedSetupRecipe = nil
        learnedSetupAttempts = []
    }
}
#endif
