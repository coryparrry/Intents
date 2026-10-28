import SwiftUI

/// Owns a content-free export span until the platform confirms its disk write or cancellation.
@MainActor final class TelemetryFileExportController {
    private var telemetry: TelemetryController?
    private var span: TelemetrySpan?
    private var generation: UUID?

    /// Replaces abandoned preparation and returns ownership that asynchronous completions must retain.
    @discardableResult func begin(_ operation: TelemetryOperation, telemetry: TelemetryController?) -> UUID {
        cancel()
        let generation = UUID()
        self.generation = generation
        self.telemetry = telemetry
        span = telemetry?.begin(operation)
        return generation
    }

    /// Measures serialization without reporting export success before the platform completes the write.
    func prepare<Value>(_ operation: TelemetryOperation, telemetry: TelemetryController?,
                        _ preparation: () throws -> Value) rethrows -> Value {
        let generation = begin(operation, telemetry: telemetry)
        do { return try preparation() }
        catch { fail(error, for: generation); throw error }
    }

    /// Publishes prepared UI state only while the asynchronous work still owns this export generation.
    @discardableResult func publish(ifCurrent expected: UUID, _ publication: () -> Void) -> Bool {
        guard generation == expected else { return false }
        publication()
        return true
    }

    /// Ends current failed preparation using a fixed category, ignoring failures from replaced work.
    func fail(_ error: any Error, for expected: UUID? = nil) {
        guard expected == nil || generation == expected else { return }
        telemetry?.end(span, failure: .classify(error))
        span = nil
        generation = nil
    }

    /// Completes the current platform write, ignoring a result explicitly bound to replaced preparation.
    func complete(_ result: Result<URL, any Error>, for expected: UUID? = nil) {
        guard expected == nil || generation == expected else { return }
        switch result {
        case .success: telemetry?.end(span)
        case .failure(let error): telemetry?.end(span, failure: .classify(error))
        }
        span = nil
        generation = nil
    }

    /// Cancels current ownership once, preventing later preparation from publishing or reporting adoption.
    func cancel(ifCurrent expected: UUID? = nil) {
        guard expected == nil || generation == expected else { return }
        telemetry?.end(span, failure: .cancelled)
        span = nil
        generation = nil
    }
}

private struct WorkflowTelemetryKey: EnvironmentKey {
    static let defaultValue: TelemetryController? = nil
}

extension EnvironmentValues {
    /// Supplies optional workflow telemetry to nested report and transcript export controls.
    var workflowTelemetry: TelemetryController? {
        get { self[WorkflowTelemetryKey.self] }
        set { self[WorkflowTelemetryKey.self] = newValue }
    }
}
