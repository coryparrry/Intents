#if os(macOS)
import Foundation
import IntentsAutomationCore

struct AutomationNativeUIFailureSearchProposal: Sendable {
    let baseline: AutomationFrozenCase
    let mutations: [AutomationMutationCase]
    let approval: AutomationSearchApproval
    var reductions: [AutomationReductionEdge] = []
    var gaps: [String] = []
    var qualifiesFixtures = false
    var qualifiesUIRequestFixture = false
    static func compile(plan: AutomationCase, approval: RunApproval, alternatePhrases: String, varySubjectRequest: Bool = false, requestFixture: AutomationUIRequestFixture? = nil) throws -> Self {
        let phrases = alternatePhrases.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard (1...2).contains(phrases.count), Set(phrases).count == phrases.count,
              phrases.allSatisfy({ $0.utf16.count <= 4096 }) else { throw AutomationContractError.invalidPlan("Enter one or two distinct alternative phrases") }
        var scoped = approval
        let searchPlan: AutomationCase
        if varySubjectRequest {
            guard let requestFixture else { throw AutomationContractError.missingEvidence("AI request search needs a disposable fresh session/reset declaration") }
            searchPlan = try requestFixture.applying(to: plan, approval: approval); scoped.effects.insert(.reset)
        } else { searchPlan = plan }
        let baseline = try AutomationFrozenCase(plan: searchPlan)
        let mutations = try phrases.map {
            if varySubjectRequest {
                return try AutomationSubjectPhraseVariation.propose(baseline: baseline, slot: .uiRequestBinding("approvedText"), request: $0,
                    semanticJustification: "Developer identified this frozen text binding as the actual AI request and approved equivalent wording for the same independent requirement")
            }
            return try AutomationGoalPhraseVariation.propose(baseline: baseline, instruction: $0,
                semanticJustification: "Developer approved alternative wording for the same visible destination and independent requirement")
        }
        let digests = Set(([baseline] + mutations.map(\.frozen)).map(\.digest))
        return .init(baseline: baseline, mutations: mutations,
            approval: .init(run: scoped, approvedDigests: digests, limits: .uiFailureSearch), qualifiesUIRequestFixture: varySubjectRequest)
    }
    static func compileFresh(plan: AutomationCase, approval: RunApproval, context: AutomationFreshEntityContext?) throws -> Self {
        let baseline = try AutomationFrozenCase(plan: plan)
        let proposed = try AutomationStateMutationPlanner.propose(baseline: baseline, context: context)
        return .init(baseline: baseline, mutations: proposed.mutations,
            approval: .init(run: approval, approvedDigests: Set(([baseline] + proposed.mutations.map(\.frozen)).map(\.digest)), limits: .init()),
            reductions: proposed.reductions, gaps: proposed.gaps, qualifiesFixtures: true)
    }
    func execute(subject: AutomationApplicationSubject, support: URL, developerDirectory: URL,
                 allowBootAndInstall: Bool) async throws -> AutomationFailureSearchReport {
        let cases = try AutomationCaseStore(root: support.appendingPathComponent("Cases"))
        let runner = try AutomationApplicationRunner(supportRoot: support,
            developerDirectory: developerDirectory)
        guard subject.target.kind == .simulator else {
            throw AutomationContractError.missingEvidence("This workflow requires a prepared simulator host")
        }
        let initialCapabilities: CapabilityProfile
        if case .prepared(let prepared) = subject { initialCapabilities = AutomationNativeFreshFixtures.capabilities(prepared) }
        else { initialCapabilities = .init() }
        var scoped = approval.run; scoped.approvedCaseDigest = baseline.digest
        let capabilities = try await runner.capabilitiesForExecution(subject: subject, plan: baseline.plan,
            capabilities: initialCapabilities, approval: scoped)
        for frozen in [baseline] + mutations.map(\.frozen) { _ = try await cases.freeze(frozen.plan) }
        let budget = try AutomationCampaignBudget(limits: approval.limits)
        var approved = approval
        let qualifications = AutomationNativeSearchQualifications()
        if qualifiesUIRequestFixture {
            var scoped = approval.run; scoped.approvedCaseDigest = baseline.digest
            do {
                let token = try await runner.qualifyUIRequestFixture(subject: subject, frozen: baseline, approval: scoped,
                    capabilities: capabilities, budget: budget, allowBootAndInstall: allowBootAndInstall,
                    onAttempt: { await qualifications.append(.init(caseDigest: baseline.digest, report: $0)) },
                    onInterrupted: { await qualifications.interrupt(.init(attemptID: $0, caseDigest: baseline.digest, stage: .baseline, dispatchMayHaveOccurred: true, reason: "UI session qualification ended without a retained result")) })
                for frozen in [baseline] + mutations.map(\.frozen) { approved.qualifiedUIRequestFixtures[frozen.digest] = token }
            } catch {
                var stopped = AutomationFailureSearchReport(baselineDigest: baseline.digest)
                stopped.qualificationAttempts = await qualifications.values; stopped.interruptions = await qualifications.interruptions
                stopped.usage = await budget.snapshot(); stopped.stopReason = "Fresh empty UI session qualification did not complete. Inspect saved attempts before repeating."
                for interruption in stopped.interruptions { stopped.counters.planned += 1; if interruption.dispatchMayHaveOccurred { stopped.counters.unresolved += 1 } else { stopped.counters.notRun += 1 } }
                return stopped
            }
        }
        if qualifiesFixtures {
            guard case .prepared(let prepared) = subject else { throw AutomationContractError.invalidIdentity }
            for frozen in [baseline] + mutations.map(\.frozen) {
                var scoped = approval.run; scoped.approvedCaseDigest = frozen.digest
                do {
                    approved.qualifiedFixtures[frozen.digest] = try await AutomationNativeFreshFixtures.qualify(frozen: frozen, prepared: prepared,
                        approval: scoped, capabilities: capabilities, runner: runner, installApproved: allowBootAndInstall,
                        campaignBudget: budget, onAttempt: { await qualifications.append(.init(caseDigest: frozen.digest, report: $0)) },
                        onInterrupted: { await qualifications.interrupt(.init(attemptID: $0, caseDigest: frozen.digest, stage: .baseline, dispatchMayHaveOccurred: true, reason: "Fixture qualification ended without a retained result")) })
                } catch {
                    var stopped = AutomationFailureSearchReport(baselineDigest: baseline.digest)
                    stopped.qualificationAttempts = await qualifications.values
                    stopped.usage = await budget.snapshot()
                    stopped.interruptions = await qualifications.interruptions
                    for interruption in stopped.interruptions { stopped.counters.planned += 1; if interruption.dispatchMayHaveOccurred { stopped.counters.unresolved += 1 } else { stopped.counters.notRun += 1 } }
                    stopped.stopReason = "Fresh setup qualification did not complete. Inspect the saved attempts before repeating it."
                    stopped.capabilityGaps = gaps
                    return stopped
                }
            }
        }
        let executor = AutomationSubjectCampaignExecutor(runner: runner, subject: subject, capabilities: capabilities,
            allowBootAndInstall: allowBootAndInstall)
        var report = try await AutomationFailureSearch(cases: cases).run(baseline: baseline, mutations: mutations, reductions: reductions,
            approval: approved, capabilities: capabilities, executor: executor, campaignBudget: budget)
        if qualifiesFixtures || qualifiesUIRequestFixture { report.qualificationAttempts = await qualifications.values }
        report.capabilityGaps += gaps
        return report
    }
}
private actor AutomationNativeSearchQualifications {
    var values: [AutomationSearchQualification] = []
    var interruptions: [AutomationSearchInterruption] = []
    func interrupt(_ value: AutomationSearchInterruption) { interruptions.append(value) }
    func append(_ value: AutomationSearchQualification) { values.append(value) }
}
typealias AutomationNativeSearchExecutor = @Sendable (AutomationNativeUIFailureSearchProposal, AutomationApplicationSubject, URL, Bool) async throws -> AutomationFailureSearchReport
#endif
