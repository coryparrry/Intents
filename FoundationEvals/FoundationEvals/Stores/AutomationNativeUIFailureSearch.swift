#if os(macOS)
import Foundation
import IntentsAutomationCore

struct AutomationNativeUIFailureSearchProposal: Sendable {
    let baseline: AutomationFrozenCase
    let mutations: [AutomationMutationCase]
    let approval: AutomationSearchApproval
    static func compile(plan: AutomationCase, approval: RunApproval, alternatePhrases: String) throws -> Self {
        let phrases = alternatePhrases.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard (1...2).contains(phrases.count), Set(phrases).count == phrases.count,
              phrases.allSatisfy({ $0.utf16.count <= 4096 }) else { throw AutomationContractError.invalidPlan("Enter one or two distinct alternative phrases") }
        let baseline = try AutomationFrozenCase(plan: plan)
        let mutations = try phrases.map {
            try AutomationGoalPhraseVariation.propose(baseline: baseline, instruction: $0,
                semanticJustification: "Developer approved alternative wording for the same visible destination and independent requirement")
        }
        let digests = Set(([baseline] + mutations.map(\.frozen)).map(\.digest))
        return .init(baseline: baseline, mutations: mutations,
            approval: .init(run: approval, approvedDigests: digests, limits: .firstCampaign))
    }
    func execute(subject: AutomationApplicationSubject, runtime: AutomationUIRuntime, support: URL, developerDirectory: URL,
                 allowBootAndInstall: Bool) async throws -> AutomationFailureSearchReport {
        let cases = try AutomationCaseStore(root: support.appendingPathComponent("Cases"))
        let runner = try AutomationApplicationRunner(supportRoot: support,
            developerDirectory: developerDirectory)
        let executor: any AutomationCampaignAttemptExecutor
        switch subject {
        case .installedMacUI: throw AutomationContractError.missingEvidence("Mac installed-app execution is not qualified")
        case .installedPhysicalUI:
            throw AutomationContractError.missingEvidence("Physical installed-app execution is not qualified")
        case .installedUI(let installed):
            executor = AutomationInstalledUICampaignExecutor(runner: runner, installed: installed,
                runtime: runtime, allowBootAndInstall: allowBootAndInstall)
        case .prepared(let prepared):
            executor = AutomationApplicationCampaignExecutor(runner: runner, prepared: prepared, capabilities: .init(),
                allowBootAndInstall: allowBootAndInstall, uiRuntime: runtime)
        }
        return try await AutomationFailureSearch(cases: cases).run(baseline: baseline, mutations: mutations,
            approval: approval, capabilities: .init(), executor: executor)
    }
}
typealias AutomationNativeSearchExecutor = @Sendable (AutomationNativeUIFailureSearchProposal, AutomationApplicationSubject, AutomationUIRuntime, URL, Bool) async throws -> AutomationFailureSearchReport
#endif
