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
