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
        let id = nativeConfirmationRequestID()
        let status: AutomationNativeCommandStatus
        let detail: String
        switch kind {
        case .run:
            let preview = try previewCommand()
            status = try requestCommand(id: id, digest: preview.digest, nativeConfirmation: true)
            detail = "App: \(preview.bundleID)\nDestination: \(preview.targetID)\nWorkflow: \(preview.action)\nPermitted effects: \(preview.effects.joined(separator: ", "))\nMaximum actions: \(preview.maximumActions)." +
                (isSiriWorkflow ? "\nExact recognised-text request: \(siriRequest)" : "") +
                (preview.installApproved ? (isSiriWorkflow ? " Intents may install the prepared app on this exact physical device." : " Intents may start this simulator and install the exact selected app.") : " Installation is not approved.") +
                (preview.disposable ? " This is a disposable test environment." : "") +
                (isSiriWorkflow && siriOracle.enabled ? " Intents will query the approved existing record before Siri, submit this exact request, and independently query that same real record after Siri. A wrong or unchanged state fails; no record is created or reset. Live qualification applies only to this frozen case and does not prove microphone recognition or remote installed bytes." : isSiriWorkflow ? " Submission remains unassessed. A returned call does not prove microphone recognition, app routing or the requested outcome." : isFreshRecordWorkflow ? " Intents creates test records, queries their actual identities, runs the selected action and independently checks their before and after states." : " Only approved independent checks will be assessed.")
        case .reproduction:
            let preview = try await previewReproductionCommand()
            status = try await requestReproductionCommand(id: id, digest: preview.digest, nativeConfirmation: true)
            detail = "App: \(preview.bundleID)\nDestination: \(preview.targetID)\nSaved attempt: \(preview.originalAttemptID)\nCase: \(preview.caseID), version \(preview.revision)\nRun five attempts with the frozen inputs, route and independent checks. The campaign is capped at 150 UI actions, 60 controller calls and 15 minutes." +
                (preview.installApproved ? " Intents may start this simulator and install the retained original app." : " No simulator installation is approved.") +
                (preview.disposable ? " Approved fixture writes stay within the disposable test environment. Fresh-record cases first run two qualification attempts, capped separately at 60 UI actions, 24 controller calls and 20 minutes." : " Only observation and navigation are allowed.")
        case .comparison:
            let preview = try await previewComparisonCommand()
            status = try await requestComparisonCommand(id: id, digest: preview.digest, nativeConfirmation: true)
            detail = "App: \(preview.bundleID)\nDestination: \(preview.targetID)\nSaved attempt: \(preview.originalAttemptID)\nOriginal build: \(preview.beforeProductDigest.prefix(12))\nFixed build: \(preview.afterProductDigest.prefix(12))\nRun 30 attempts per build with unchanged inputs, route and checks. Each build is capped at 900 UI actions, 360 controller calls and 90 minutes. Observed counts do not guarantee future reliability." +
                (preview.installApproved ? " Intents will install each retained build on this simulator." : " Intents will use the retained Mac app bundles.") +
                (preview.disposable ? " Approved fixture writes stay within the disposable test environment; fresh-record cases also run two qualification attempts per build, capped separately at 60 UI actions, 24 controller calls and 20 minutes." : " Only observation and navigation are allowed.")
        }
        guard status.state == "awaitingApproval", pendingCommandStatus?.requestID == id,
              pendingCommandStatus?.digest == status.digest else { throw AutomationContractError.conflictingOperation }
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
            guard canRun, try previewCommand().digest == review.digest else {
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
