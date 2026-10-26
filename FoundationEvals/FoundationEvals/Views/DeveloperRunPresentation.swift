import Foundation
#if canImport(FoundationEvalsDeveloper)
import FoundationEvalsDeveloper
#endif

/// Human-readable labels for persisted app-feature evidence and runner failures.
enum DeveloperRunPresentation {
    /// Labels app-feature runs with the runner name, otherwise using the recorded provider or a missing-provider fallback.
    static func providerLabel(for run: EvaluationRun) -> String {
        if let execution = run.developerExecution {
            return "App feature · \(execution.runnerName)"
        }
        return run.execution?.configuration.provider.title ?? "Provider not recorded"
    }

    /// Prefers a noninternal sample or status message, falling back to a connection- or timeout-specific explanation.
    static func failureMessage(for status: DeveloperRunStatus, sampleMessage: String?) -> String {
        for message in [sampleMessage, status.detail] {
            if let value = message?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty, !value.hasPrefix("developerRunner:") {
                return value
            }
        }
        switch status.phase {
        case .disconnected:
            return "The connection to the app was lost. Reconnect the device and try again."
        case .timedOut:
            return "The app did not respond before the time limit. Check the device and try again."
        default:
            return "The device run could not finish. Check its connection and try again."
        }
    }
}
