import Foundation

enum ScenarioRecoveryFailure: String, Codable, Sendable {
    case buildFailure
    case cancellation
    case timeout
    case deviceDisconnect
    case incompleteResultBundle
    case invalidEvidence
    case unexpected
}

enum ScenarioExecutionRecoveryPolicy {
    static func hasBoundJournal(run: ScenarioRun, journals: [ScenarioExecutionJournal]) -> Bool {
        journals.contains { journal in
            journal.id == run.id
                && journal.invocation.nonce == run.invocation.nonce
                && journal.invocation.testIdentity == run.invocation.testIdentity
                && journal.invocation.harnessVersion == run.invocation.harnessVersion
                && journal.invocation.destinationIdentifier == run.invocation.destinationIdentifier
                && journal.invocation.scenarioDigest == run.invocation.scenarioDigest
                && journal.invocation.resultBundleIdentity == run.invocation.resultBundleIdentity
                && journal.invocation.appProduct == run.invocation.appProduct
                && journal.invocation.testProduct == run.invocation.testProduct
                && journal.scenarioID == run.scenarioID
                && journal.scenarioVersion == run.scenarioVersion
        }
    }

    static func hasTerminalBusinessFailure(_ run: ScenarioRun) -> Bool {
        guard run.executionStatus == .completed, run.outcome == .failed,
              run.laneResults.count == 1 else { return false }
        let lane = run.laneResults[0]
        guard lane.executionStatus == .completed, lane.outcome == .failed else { return false }
        switch lane.actionFailureReason {
        case .some(.wrongAction), .some(.wrongParameter), .some(.wrongOutcome),
             .some(.unexpectedExecution), .some(.operationError):
            return true
        case .some(.missingActionEvidence), .some(.staleActionEvidence),
             .some(.invalidActionEvidence), .none:
            return false
        }
    }

    static func shouldPreserveTerminalBusinessFailure(
        _ run: ScenarioRun,
        attachment: ScenarioEvidenceAttachment
    ) -> Bool {
        !attachment.isCheckpoint && hasTerminalBusinessFailure(run)
    }

    static func acceptsFinalEvidence(
        attachments: [ScenarioEvidenceAttachment],
        runs: [ScenarioRun],
        xctestExitCode: Int32
    ) -> Bool {
        let hasFinalEnvelope = !attachments.isEmpty && attachments.allSatisfy { !$0.isCheckpoint }
        let hasCompletedRuns = !runs.isEmpty && runs.allSatisfy { run in
                run.executionStatus == .completed
                    && !run.laneResults.isEmpty
                    && run.laneResults.allSatisfy { $0.executionStatus == .completed }
            }
        guard hasFinalEnvelope, hasCompletedRuns else { return false }
        // The XCTest process status is independent of an imported business
        // result. A completed failure can be retained for display, but a
        // nonzero process status never qualifies as complete evidence.
        guard xctestExitCode == 0 else { return false }
        return runs.allSatisfy { $0.xctestExitCode == xctestExitCode }
    }

    static func requiresQuarantine(
        deviceTestLaunched: Bool,
        failure: ScenarioRecoveryFailure
    ) -> Bool {
        switch failure {
        case .buildFailure:
            false
        case .cancellation, .timeout, .deviceDisconnect, .incompleteResultBundle,
             .invalidEvidence, .unexpected:
            deviceTestLaunched
        }
    }

    static func reason(for failure: ScenarioRecoveryFailure) -> String {
        switch failure {
        case .buildFailure:
            "The test bundle failed before device execution began."
        case .cancellation:
            "Cancellation does not prove the device-side test stopped or that fixture state is ready."
        case .timeout:
            "The execution deadline elapsed; late results remain bound to the timed-out invocation."
        case .deviceDisconnect:
            "The device disconnected before termination and fixture readiness were proven."
        case .incompleteResultBundle:
            "The device test ended without a complete, attributable evidence bundle."
        case .invalidEvidence:
            "The returned evidence could not be attributed safely to the active invocation."
        case .unexpected:
            "The device-side terminal state and fixture readiness could not be established."
        }
    }
}
