#if os(macOS)
import Foundation
import IntentsAutomationCore

struct AutomationNativePreparationReview: Sendable {
    let candidate: AutomationApplicationCandidate
    let configuration: String
    let target: TargetIdentity
    let selectionEpoch: Int
    let sourceRoot: String
    let additionalSourceRoots: [String]
    let message: String
}
struct AutomationNativeSearchReview: Sendable {
    let digest: String
    let selectionEpoch: Int
    let message: String
}
extension AppAutomationStore {
    func reviewNativePreparation() throws -> AutomationNativePreparationReview {
        guard canPrepare, let candidate, let target = sourcePreparationTarget, let root = selectedSourceRoot else { throw AutomationContractError.conflictingOperation }
        _ = try AutomationSourceSnapshot.validateRoots(source: root, additionalRoots: sourceGrants.urls)
        let extras = sourceGrants.urls.map(\.path)
        return .init(candidate: candidate, configuration: configuration, target: target, selectionEpoch: selectionEpoch,
            sourceRoot: root.path, additionalSourceRoots: extras,
            message: "App: \(candidate.name)\nProject: \(candidate.containerPath)\nSource folder: \(root.path)\nAdditional source folders: \(extras.isEmpty ? "None" : "\n" + extras.joined(separator: "\n"))\nConfiguration: \(configuration)\nDestination: \(target.kind == .nativeMac ? "This Mac" : target.id)\nXcode may resolve dependencies and run this project's build scripts. Intents freezes the current files and adds its host to a private copy.")
    }
    func confirmNativePreparation(_ review: AutomationNativePreparationReview) throws {
        guard canPrepare, candidate == review.candidate, configuration == review.configuration,
              sourcePreparationTarget == review.target, selectionEpoch == review.selectionEpoch,
              selectedSourceRoot?.path == review.sourceRoot, sourceGrants.urls.map(\.path) == review.additionalSourceRoots else { throw AutomationContractError.conflictingOperation }
        if savedAttemptLoading { clearSavedView() }
        selectionEpoch += 1; invalidatePendingCommand()
        prepare(expectedTarget: review.target)
    }
    func reviewNativeSearch() throws -> AutomationNativeSearchReview {
        guard canFindFailures else { throw AutomationContractError.conflictingOperation }
        let request = try makeUIRunRequest(runID: "preview")
        let proposal = try AutomationNativeUIFailureSearchProposal.compile(plan: request.plan, approval: request.approval, alternatePhrases: uiAlternatePhrases)
        return .init(digest: try Self.nativeSearchDigest(request, proposal), selectionEpoch: selectionEpoch,
            message: "App: \(request.plan.app.bundleID)\nDestination: \(request.plan.target.id)\nAlternative phrases:\n\(uiAlternatePhrases)\nThe selected workflow and these phrases share one frozen business check. Only observation and navigation are allowed. Up to 20 attempts, 1,000 UI actions, 300 controller calls and one hour." +
                (request.installApproved ? " Intents may start this simulator and install the exact selected app." : " The app must already be installed on the running simulator."))
    }
    static func nativeSearchDigest(_ request: AutomationNativeRunRequest, _ proposal: AutomationNativeUIFailureSearchProposal) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let fields = ["request": request.digest, "baseline": proposal.baseline.digest,
            "mutations": proposal.mutations.map { $0.frozen.digest }.joined(separator: ","),
            "limits": AutomationArtifactRegistry.digest(try encoder.encode(proposal.approval.limits))]
        return AutomationArtifactRegistry.digest(try encoder.encode(fields))
    }
}
#endif
