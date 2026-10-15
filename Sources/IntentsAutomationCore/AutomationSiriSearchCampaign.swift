#if os(macOS)
import Foundation

/// The only campaign adapter that admits repeated Siri record-state trials.
/// Authority belongs to each exact phrase, prepared host and current process.
public struct AutomationSiriCampaignExecutor: AutomationCampaignAttemptExecutor {
    public let runner: AutomationApplicationRunner
    public let prepared: AutomationPreparedApplication
    public let capabilities: CapabilityProfile
    public let authorities: [String: AutomationSiriRouteAuthority]
    public init(runner: AutomationApplicationRunner, prepared: AutomationPreparedApplication, capabilities: CapabilityProfile,
                authorities: [String: AutomationSiriRouteAuthority]) {
        self.runner = runner; self.prepared = prepared; self.capabilities = capabilities; self.authorities = authorities
    }
    public func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String,
                        budget: AutomationCampaignBudget) async throws -> AutomationAttemptReport {
        guard let authority = authorities[frozen.digest] else { throw AutomationContractError.missingEvidence("Missing exact-phrase Siri qualification") }
        return try await runner.runQualifiedSiriWorkflow(prepared: prepared, plan: frozen.plan, approval: approval,
            capabilities: capabilities, attemptID: attemptID, authority: authority, campaignBudget: budget)
    }
}

public enum AutomationSiriSearchCampaign {
    /// Internal test seam; native consumers and decoded archives cannot supply live factories.
    struct Dependencies: Sendable {
        let qualify: @Sendable (AutomationFrozenCase, RunApproval, String, AutomationCampaignBudget) async throws -> AutomationAttemptReport
        let authority: @Sendable (AutomationFrozenCase, RunApproval) async -> AutomationSiriRouteAuthority?
        let executor: @Sendable ([String: AutomationSiriRouteAuthority]) -> any AutomationCampaignAttemptExecutor
    }
    public static func run(baseline: AutomationFrozenCase, mutations: [AutomationMutationCase], approval: AutomationSearchApproval,
                           prepared: AutomationPreparedApplication, capabilities: CapabilityProfile,
                           runner: AutomationApplicationRunner, cases: AutomationCaseStore) async throws -> AutomationFailureSearchReport {
        try await run(baseline: baseline, mutations: mutations, approval: approval, prepared: prepared,
            capabilities: capabilities, cases: cases, dependencies: .init(
                qualify: { frozen, scoped, attemptID, budget in
                    try await runner.qualifySiriWorkflow(prepared: prepared, plan: frozen.plan, approval: scoped,
                        capabilities: capabilities, attemptID: attemptID, allowInstall: true, campaignBudget: budget)
                }, authority: { frozen, scoped in
                    await runner.qualifiedSiriAuthority(prepared: prepared, plan: frozen.plan, approval: scoped)
                }, executor: { authorities in
                    AutomationSiriCampaignExecutor(runner: runner, prepared: prepared, capabilities: capabilities, authorities: authorities)
                }))
    }
    static func run(baseline: AutomationFrozenCase, mutations: [AutomationMutationCase], approval: AutomationSearchApproval,
                    prepared: AutomationPreparedApplication, capabilities: CapabilityProfile, cases: AutomationCaseStore,
                    dependencies: Dependencies) async throws -> AutomationFailureSearchReport {
        try baseline.validate(); try AutomationSiriRepeatableQualification.validateStructure(plan: baseline.plan, approval: approval.run)
        let population = [baseline] + mutations.map(\.frozen)
        guard (1...2).contains(mutations.count), Set(population.map(\.digest)).count == population.count,
              approval.approvedDigests == Set(population.map(\.digest)), approval.run.disposable,
              approval.run.app == prepared.host.app, approval.run.target == prepared.host.target,
              approval.qualifiedSiriAuthorities.isEmpty else { throw AutomationContractError.invalidIdentity }
        for mutation in mutations {
            guard mutation.subjectPhraseSlot == .siriRecognizedText else { throw AutomationContractError.invalidIdentity }
            try AutomationSubjectPhraseVariation.validate(mutation, baseline: baseline)
        }
        let budget = try AutomationCampaignBudget(limits: approval.limits)
        var approved = approval
        var qualifications: [AutomationSearchQualification] = []
        var stopped = AutomationFailureSearchReport(baselineDigest: baseline.digest)
        for frozen in population { _ = try await cases.freeze(frozen.plan) }
        for frozen in population {
            var scoped = approval.run; scoped.approvedCaseDigest = frozen.digest
            for _ in 0..<2 {
                let attemptID = UUID().uuidString
                var reserved = false
                do {
                    try await budget.reserveAttempt(id: attemptID); reserved = true
                    let report = try await dependencies.qualify(frozen, scoped, attemptID, budget)
                    qualifications.append(.init(caseDigest: frozen.digest, report: report))
                    guard (try? AutomationSiriSubmissionQualification.validate(report: report, plan: frozen.plan, approval: scoped)) != nil else {
                        stopped.stopReason = "Siri submission-channel qualification did not complete safely. Inspect the retained attempt before repeating."; break
                    }
                } catch {
                    if reserved { stopped.interruptions.append(.init(attemptID: attemptID, caseDigest: frozen.digest, stage: .baseline,
                        dispatchMayHaveOccurred: true, reason: "Owned Siri qualification ended without a complete retained result")) }
                    stopped.stopReason = error is CancellationError ? "Cancelled" : "Siri qualification stopped: " + String(describing: error)
                    break
                }
            }
            if stopped.stopReason != nil { break }
            guard let authority = await dependencies.authority(frozen, scoped),
                  (try? AutomationSiriRepeatableQualification.validate(plan: frozen.plan, approval: scoped, authority: authority)) != nil else {
                stopped.stopReason = "Two live exact-phrase Siri qualifications did not establish submission-channel authority"; break
            }
            approved.qualifiedSiriAuthorities[frozen.digest] = authority
        }
        if stopped.stopReason != nil {
            stopped.qualificationAttempts = qualifications; stopped.usage = await budget.snapshot()
            for interruption in stopped.interruptions { stopped.counters.planned += 1; if interruption.dispatchMayHaveOccurred { stopped.counters.unresolved += 1 } else { stopped.counters.notRun += 1 } }
            return stopped
        }
        let executor = dependencies.executor(approved.qualifiedSiriAuthorities)
        var result = try await AutomationFailureSearch(cases: cases).run(baseline: baseline, mutations: mutations,
            approval: approved, capabilities: capabilities, executor: executor, campaignBudget: budget)
        result.qualificationAttempts = qualifications
        return result
    }
}
#endif
