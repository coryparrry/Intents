import Foundation

enum AutomationNativeSecretDeadline {
    @TaskLocal static var value: ContinuousClock.Instant?
    static func check() throws {
        try Task.checkCancellation()
        guard let value, ContinuousClock.now < value else { throw AutomationSecretFillSession.Failure.denied }
    }
}

/// Immediate cancellation before an actor hop, plus a publication latch.
final class AutomationNativeTaskRevocation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    private var task: Task<Value, Error>?
    var isRevoked: Bool { lock.withLock { revoked } }
    func install(_ value: Task<Value, Error>) -> Bool {
        lock.withLock { if revoked { return false }; task = value; return true }
    }
    func retire() { lock.withLock { task = nil } }
    func revoke() {
        let value = lock.withLock { revoked = true; return task }; value?.cancel()
    }
}
