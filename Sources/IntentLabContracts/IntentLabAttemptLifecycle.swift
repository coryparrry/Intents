import Foundation

/// Runs cleanup for every normally returned attempt, including thrown actions.
/// A process or XCTest interruption that does not unwind Swift cannot reach this code.
public enum IntentLabAttemptLifecycle {
    public static func execute<Value>(
        action: () throws -> Value,
        cleanupRequired: () -> Bool,
        skipCleanupAfter: (Error) -> Bool = { _ in false },
        cleanup: () throws -> Void
    ) -> (action: Result<Value, Error>, cleanupError: Error?) {
        let result = Result { try action() }
        guard cleanupRequired() else { return (result, nil) }
        if case .failure(let error) = result, skipCleanupAfter(error) {
            return (result, nil)
        }
        do {
            try cleanup()
            return (result, nil)
        } catch {
            return (result, error)
        }
    }
}
