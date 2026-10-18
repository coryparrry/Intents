#if os(macOS)
import Foundation
import IntentsAutomationCore

enum AutomationNativeConfirmationKind: Equatable, Sendable { case run, reproduction, comparison }
struct AutomationNativeConfirmationReview: Sendable {
    let id: UUID
    let digest: String
    let kind: AutomationNativeConfirmationKind
    let message: String
}

extension AppAutomationStore {
    /// Native dialogs and remote requests use the same frozen request boundary.
    func prepareNativeConfirmation(_ kind: AutomationNativeConfirmationKind) async throws -> AutomationNativeConfirmationReview {
        let expected: AutomationNativeCommandKind? = switch kind {
        case .run: nil
        case .reproduction: .reproduction
        case .comparison: .fixComparison
        }
        let id: UUID
        if let pending = pendingCommandStatus {
            guard pending.kind == expected, pending.state == "awaitingApproval" else {
                throw AutomationContractError.conflictingOperation
            }
            id = pending.requestID
        } else {
            id = nativeConfirmationRequestID()
        }
        let status: AutomationNativeCommandStatus
        var detail: String
        switch kind {
        case .run:
            let preview = try await verifiedPreviewCommand()
            status = try installVerifiedConfirmation(id: id, digest: preview.digest, kind: nil)
            detail = "App: \(preview.bundleID)\nDestination: \(preview.targetID)\nWorkflow: \(preview.action)\nPermitted effects: \(preview.effects.joined(separator: ", "))\nMaximum actions: \(preview.maximumActions)." +
                (isSiriWorkflow ? "\nExact recognised-text request: \(siriRequest)" : "") +
                (preview.installApproved ? (isSiriWorkflow ? " Intents may install the prepared app on this exact physical device." : " Intents may start this simulator and install the exact selected app.") : (preview.targetID == "host-macos-local" ? " Intents will launch the retained Mac app and its associated test host in this login session." : " Installation is not approved.")) +
                (preview.disposable ? " This is a disposable test environment." : "") +
                (isSiriWorkflow && siriOracle.enabled ? " Intents will query the approved existing record before Siri, submit this exact request, and independently query that same real record after Siri. A wrong or unchanged state fails; no record is created or reset. The saved check does not prove microphone recognition or remote installed bytes." : isSiriWorkflow ? " Submission remains unassessed. A returned call does not prove microphone recognition, app routing or the requested outcome." : isFreshRecordWorkflow ? " Intents creates test records, queries their actual identities, runs the selected action and independently checks their before and after states." : " Only approved independent checks will be assessed.")
        case .reproduction:
            let preview = try await previewReproductionCommand()
            status = try installVerifiedConfirmation(id: id, digest: preview.digest, kind: .reproduction,
                originalAttemptID: preview.originalAttemptID, caseID: preview.caseID, revision: preview.revision, caseDigest: preview.caseDigest)
            detail = "App: \(preview.bundleID)\nDestination: \(preview.targetID)\nSaved attempt: \(preview.originalAttemptID)\nCase: \(preview.caseID), version \(preview.revision)\nRun five attempts with the frozen inputs, route and independent checks. The campaign is capped at 150 UI actions and 15 minutes." +
                (preview.installApproved ? " Intents may start this simulator and install the retained original app." : " Intents will use the retained app and its associated test host.") +
                (preview.disposable ? " Approved fixture writes stay within the disposable test environment." : " Only observation and navigation are allowed.")
        case .comparison:
            let preview = try await previewComparisonCommand()
            status = try installVerifiedConfirmation(id: id, digest: preview.digest, kind: .fixComparison,
                originalAttemptID: preview.originalAttemptID, caseID: preview.caseID, revision: preview.revision, caseDigest: preview.caseDigest)
            detail = "App: \(preview.bundleID)\nDestination: \(preview.targetID)\nSaved attempt: \(preview.originalAttemptID)\nOriginal build: \(preview.beforeProductDigest.prefix(12))\nFixed build: \(preview.afterProductDigest.prefix(12))\nRun \(preview.requestedAttemptsPerBuild) attempts per build with unchanged inputs, route and checks. Each attempt allows up to 30 UI actions and three minutes. Observed counts do not guarantee future reliability." +
                (preview.installApproved ? " Intents will install each retained build on this simulator." : " Intents will use the retained Mac app bundles.") +
                (preview.disposable ? " Approved fixture writes stay within the disposable test environment." : " Only observation and navigation are allowed.")
        }
        guard status.state == "awaitingApproval", pendingCommandStatus?.requestID == id,
              pendingCommandStatus?.digest == status.digest else { throw AutomationContractError.conflictingOperation }
        if kind == .run, prepared?.host.target.kind == .nativeMac, !isUIWorkflow, !isSiriWorkflow {
            detail += " Intents checks the prepared host’s typed input support before running the approved action."
        }
        return .init(id: id, digest: status.digest, kind: kind, message: detail)
    }
    func confirmNativeRequest(_ review: AutomationNativeConfirmationReview) async throws {
        let expected: AutomationNativeCommandKind? = switch review.kind {
        case .run: nil
        case .reproduction: .reproduction
        case .comparison: .fixComparison
        }
        guard let pending = pendingCommandStatus, pending.requestID == review.id, pending.digest == review.digest,
              pending.kind == expected, pending.state == "awaitingApproval" else { throw AutomationContractError.conflictingOperation }
        switch review.kind {
        case .run:
            let preview: AutomationNativeCommandPreview
            do { preview = try await verifiedPreviewCommand() }
            catch { invalidatePendingCommand(); throw error }
            guard canRun, preview.digest == review.digest, pendingCommandStatus?.requestID == review.id,
                  pendingCommandStatus?.state == "awaitingApproval" else {
                invalidatePendingCommand(); throw AutomationContractError.conflictingOperation
            }
            run()
        case .reproduction:
            guard canReproduceSavedFailure else { throw AutomationContractError.conflictingOperation }; await reproduceSavedFailure()
        case .comparison:
            guard canCheckFix else { throw AutomationContractError.conflictingOperation }; await checkFix()
        }
    }

}
#endif
