#if os(macOS)
import Foundation
import IntentsAutomationCore

/// Internal native admission dependency. Production reviewers always verify the closed runtime tree.
/// The app leaves this dependency absent while the Mac execution route remains unqualified.
struct AutomationNativeMacSavedRuntime: Sendable {
    typealias ReproductionReviewer = @Sendable (AutomationFrozenCase, AutomationAttemptReport, AutomationInstalledMacUIApplication, URL, String) throws -> AutomationMacSavedWorkflowContract.Reproduction
    typealias ComparisonReviewer = @Sendable (AutomationFrozenCase, AutomationAttemptReport, AutomationInstalledMacUIApplication, AutomationInstalledMacUIApplication, URL, String) throws -> AutomationMacSavedWorkflowContract.Comparison
    let root: URL
    var reproductionReviewer: ReproductionReviewer = { try AutomationMacSavedWorkflowContract.reproduction(frozen: $0, original: $1, selected: $2, runtimeRoot: $3, runID: $4) }
    var comparisonReviewer: ComparisonReviewer = { try AutomationMacSavedWorkflowContract.comparison(frozen: $0, original: $1, before: $2, after: $3, runtimeRoot: $4, runID: $5) }

    func reproduction(frozen: AutomationFrozenCase, original: AutomationAttemptReport,
                      selected: AutomationInstalledMacUIApplication, runID: String) throws -> AutomationNativeReproductionRequest {
        let review = try reproductionReviewer(frozen, original, selected, root, runID)
        let proposal = AutomationNativeUIReproductionProposal.fromMacReview(review)
        var fields = try identityFields(original: original, evidence: review.runtimeEvidence)
        fields["case"] = frozen.digest; fields["install"] = "false"; fields["disposable"] = "false"; fields["attempts"] = "5"
        fields["uiActions"] = String(proposal.limits.uiActions); fields["controllerCalls"] = String(proposal.limits.controllerCalls)
        fields["wallClockSeconds"] = String(proposal.limits.wallClockSeconds)
        return .init(proposal: proposal, subject: .installedMacUI(selected), runtime: nil, installApproved: false, digest: try digest(fields))
    }
    func comparison(frozen: AutomationFrozenCase, original: AutomationAttemptReport,
                    before: AutomationInstalledMacUIApplication, after: AutomationInstalledMacUIApplication,
                    runID: String) throws -> AutomationNativeFixComparisonRequest {
        let review = try comparisonReviewer(frozen, original, before, after, root, runID)
        let proposal = AutomationNativeUIFixComparisonProposal.fromMacReview(review)
        var fields = try identityFields(original: original, evidence: review.runtimeEvidence)
        fields["baseline"] = proposal.baseline.digest; fields["candidate"] = proposal.candidate.digest
        fields["beforeBuild"] = try AutomationArtifactRegistry.digest(encoder().encode(before.app))
        fields["afterBuild"] = try AutomationArtifactRegistry.digest(encoder().encode(after.app))
        fields["install"] = "false"; fields["disposable"] = "false"; fields["attemptsPerBuild"] = "30"
        fields["uiActions"] = String(proposal.limits.uiActions); fields["controllerCalls"] = String(proposal.limits.controllerCalls)
        fields["wallClockSeconds"] = String(proposal.limits.wallClockSeconds)
        return .init(proposal: proposal, before: .installedMacUI(before), after: .installedMacUI(after), runtime: nil,
            digest: try digest(fields), originalAttemptID: original.attemptID)
    }
    private func identityFields(original: AutomationAttemptReport, evidence: AutomationPrivateMacDaemonUnit.Evidence) throws -> [String: String] {
        ["original": try AutomationArtifactRegistry.digest(encoder().encode(original)),
         "runtimeRoot": try AutomationPath.canonical(root).path, "runtimeReceipt": evidence.receiptSHA256,
         "runtimeCheckpoint": evidence.checkpointSHA256]
    }
    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return encoder
    }
    private func digest(_ fields: [String: String]) throws -> String { try AutomationArtifactRegistry.digest(encoder().encode(fields)) }
}
#endif
