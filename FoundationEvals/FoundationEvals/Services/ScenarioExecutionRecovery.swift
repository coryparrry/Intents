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
    static func canReevaluateFeature(captured: ScenarioMeasurementImplementation?, current: ScenarioMeasurementImplementation?) -> Bool {
        captured == nil || captured == current
    }

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

    static func hasTerminalBusinessFailure(_ run: ScenarioRun, definition: ScenarioDefinition?) -> Bool {
        guard let definition, run.executionStatus == .completed, run.outcome == .failed,
              run.laneResults.contains(where: { $0.outcome == .failed }) else { return false }
        return run.laneResults.allSatisfy { lane in
            guard lane.executionStatus == .completed else { return false }
            if lane.outcome == .passed { return true }
            guard lane.outcome == .failed else { return false }
            return definition.assertions.contains { assertion in
                guard assertion.required, assertion.applies(to: lane.lane),
                      let expected = assertion.expectedValue,
                      let observed = lane.observations[assertion.observationKey], observed != expected else { return false }
                return lane.assertionResults.contains { $0.assertionID == assertion.id && !$0.passed }
            }
        }
    }

    static func shouldPreserveTerminalBusinessFailure(_ run: ScenarioRun, attachment: ScenarioEvidenceAttachment, definition: ScenarioDefinition? = nil) -> Bool {
        !attachment.isCheckpoint && hasTerminalBusinessFailure(run, definition: definition)
    }

    static func acceptsFinalEvidence(
        attachments: [ScenarioEvidenceAttachment], runs: [ScenarioRun], xctestExitCode: Int32,
        definition: ScenarioDefinition? = nil
    ) -> Bool {
        !attachments.isEmpty && attachments.allSatisfy { !$0.isCheckpoint }
            && !runs.isEmpty && runs.allSatisfy { run in
                run.executionStatus == .completed && !run.laneResults.isEmpty
                    && run.laneResults.allSatisfy { $0.executionStatus == .completed }
            }
            && (xctestExitCode == 0 || runs.allSatisfy { hasTerminalBusinessFailure($0, definition: definition) })
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
