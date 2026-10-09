import Foundation

/// The deadline ends the await, not the underlying device operation. Callers
/// retain ownership until both this task and the driver's runner are drained.
actor AutomationBoundedTask<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private(set) var workFinished = false
    private(set) var started = false
    func run(until deadline: ContinuousClock.Instant, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw AutomationRPCError.timedOut }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let result { continuation.resume(with: result); return }
                self.continuation = continuation
                started = true
                work = Task {
                    let outcome: Result<Value, any Error>
                    do {
                        try Task.checkCancellation()
                        guard ContinuousClock.now < deadline else { throw AutomationRPCError.timedOut }
                        outcome = .success(try await operation())
                    }
                    catch { outcome = .failure(error) }
                    workFinished = true; finish(outcome)
                }
                timer = Task {
                    do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                    finish(.failure(AutomationRPCError.timedOut)); work?.cancel()
                }
            }
        } onCancel: { Task { await self.cancel() } }
    }
    private func cancel() { finish(.failure(CancellationError())); work?.cancel() }
    func requestCancellation() { cancel() }
    /// Ending the await does not prove that the underlying operation has settled.
    func cancelAndDrain(until deadline: ContinuousClock.Instant) async -> Bool {
        cancel()
        while started && !workFinished && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return !started || workFinished
    }
    private func finish(_ outcome: Result<Value, any Error>) {
        guard result == nil else { return }
        result = outcome; timer?.cancel(); continuation?.resume(with: outcome); continuation = nil
    }
}
