import Foundation

/// An interrupted direct or Siri intent may still complete outside the UI-test process.
/// Keep later attempts from resetting its application state in this process.
public struct IntentLabAttemptFence: Sendable {
    private enum State: Sendable { case available, unresolvedDirectIntent, siriInProgress }
    private var state: State = .available

    public var isQuarantined: Bool {
        if case .available = state { return false }
        return true
    }

    public init() {}

    public mutating func recordUnresolvedDirectTimeout() {
        state = .unresolvedDirectIntent
    }

    /// Call before entering Siri activation. If XCTest interrupts the stack,
    /// the next run remains fenced even when no Swift catch block executes.
    public mutating func beginSiriAttempt() throws {
        try validateNewAttempt()
        state = .siriInProgress
    }

    /// Only a correlated, independently observed completion can clear Siri's fence.
    /// A direct timeout has no corresponding local recovery path.
    public mutating func recordVerifiedSiriCompletion() {
        if case .siriInProgress = state { state = .available }
    }

    public func validateNewAttempt() throws {
        switch state {
        case .available: return
        case .unresolvedDirectIntent: throw IntentLabAttemptFenceError.unresolvedDirectIntent
        case .siriInProgress: throw IntentLabAttemptFenceError.unresolvedSiriAttempt
        }
    }
}

public enum IntentLabAttemptFenceError: LocalizedError {
    case unresolvedDirectIntent
    case unresolvedSiriAttempt

    public var errorDescription: String? {
        switch self {
        case .unresolvedDirectIntent:
            "A prior direct intent timed out in this UI-test process; a new attempt could reuse its state."
        case .unresolvedSiriAttempt:
            "A prior Siri attempt has no correlated completion in this UI-test process; a new attempt could reuse its state."
        }
    }
}
