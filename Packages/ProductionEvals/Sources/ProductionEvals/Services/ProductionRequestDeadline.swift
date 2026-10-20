import Foundation

/// The executor may ignore cancellation. Scope exit must not wait for it, and
/// its eventual result must never replace the winning deadline/cancellation.
enum ProductionRequestDeadline {
    struct Exceeded: Error, LocalizedError, Sendable {
        var errorDescription: String? {
            "Request deadline exceeded. Cancellation was requested, but executor completion is unverified. The job is paused; inspect the recorded evidence before resuming."
        }
    }

    static func run<Value: Sendable>(seconds: Double,
        operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let race = Race<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            await race.start(seconds: seconds, operation: operation)
            return try await race.wait()
        } onCancel: {
            Task { await race.finish(.failure(CancellationError())) }
        }
    }

    private actor Race<Value: Sendable> {
        private var result: Result<Value, any Error>?
        private var continuation: CheckedContinuation<Value, any Error>?
        private var tasks: [Task<Void, Never>] = []

        func start(seconds: Double, operation: @escaping @Sendable () async throws -> Value) {
            guard result == nil else { return }
            // These unstructured tasks intentionally outlive the waiting scope
            // when an executor is non-cooperative. Weak captures release the
            // race after return; neither task can commit batch evidence.
            let execution = Task { @concurrent [weak self] in
                do {
                    let value = try await operation()
                    await self?.finish(.success(value))
                }
                catch { await self?.finish(.failure(error)) }
            }
            let timer = Task { @concurrent [weak self] in
                do {
                    try await Task.sleep(for: .seconds(seconds))
                    await self?.finish(.failure(Exceeded()))
                } catch { /* A completed operation cancels its timer. */ }
            }
            tasks = [execution, timer]
        }

        func wait() async throws -> Value {
            try await withCheckedThrowingContinuation { continuation in
                if let result { continuation.resume(with: result) }
                else { self.continuation = continuation }
            }
        }

        func finish(_ result: Result<Value, any Error>) {
            guard self.result == nil else { return }
            self.result = result
            for task in tasks { task.cancel() }
            tasks.removeAll()
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}
