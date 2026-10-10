import Foundation

/// An admitted native run reports one result through its original telemetry span.
public typealias AutomationRunTelemetryCompletion = @MainActor @Sendable (Result<AutomationAttemptReport, any Error>) -> Void

@MainActor
public protocol AutomationRunTelemetry: AnyObject {
    func beginAutomationRun() -> AutomationRunTelemetryCompletion
}
