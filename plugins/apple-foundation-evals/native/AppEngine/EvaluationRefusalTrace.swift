import Foundation
import FoundationModels

@available(macOS 27.0, *)
struct EvaluationRefusalTrace: Codable, Equatable, Sendable {
    static let maximumExplanationCharacters = 4_096
    static let maximumFailureMessageCharacters = 512
    static let generationTimeout: Duration = .seconds(3)

    var explanation: String?
    var explanationGenerationFailed: Bool
    var explanationFailureMessage: String?
    var explanationWasTruncated: Bool

    /// Captures bounded explanation evidence only for Foundation Models refusal errors; returns nil for other failures.
    static func capture(
        from error: any Error,
        timeout: Duration = generationTimeout,
        maximumCharacters: Int = maximumExplanationCharacters
    ) async -> Self? {
        guard let modelError = error as? LanguageModelError,
              case .refusal(let refusal) = modelError else {
            return nil
        }

        return await captureExplanation(
            timeout: timeout,
            maximumCharacters: maximumCharacters
        ) {
            try await refusal.explanation.content
        }
    }

    /// Generates refusal explanation evidence with the default sleep-based deadline and caller cancellation handling.
    static func captureExplanation(
        timeout: Duration = generationTimeout,
        maximumCharacters: Int = maximumExplanationCharacters,
        operation: @escaping @Sendable () async throws -> String
    ) async -> Self {
        await captureExplanation(
            timeout: timeout,
            maximumCharacters: maximumCharacters,
            timeoutWait: { duration in
                try await Task.sleep(for: duration)
            },
            operation: operation
        )
    }

    /// Races explanation generation against an injected deadline without waiting for a losing operation to cooperate with cancellation.
    /// Trims and bounds successful text, and records empty, failed, timed-out, or cancelled generation as failure evidence.
    static func captureExplanation(
        timeout: Duration,
        maximumCharacters: Int = maximumExplanationCharacters,
        timeoutWait: @escaping @Sendable (Duration) async throws -> Void,
        operation: @escaping @Sendable () async throws -> String
    ) async -> Self {
        guard !Task.isCancelled else {
            return failed("Refusal explanation generation was cancelled.")
        }

        let race = EvaluationRefusalExplanationRace()
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard race.register(continuation) else { return }
                guard !Task.isCancelled else {
                    race.resolve(.cancelled)
                    return
                }

                let gate = AsyncStream<Void>.makeStream()
                let explanationTask = Task {
                    var iterator = gate.stream.makeAsyncIterator()
                    _ = await iterator.next()
                    guard !Task.isCancelled else { return }

                    do {
                        try Task.checkCancellation()
                        race.resolve(.explanation(try await operation()))
                    } catch {
                        race.resolve(.failure(boundedFailureMessage(error.localizedDescription)))
                    }
                }
                let timeoutTask = Task {
                    do {
                        try await timeoutWait(timeout)
                        race.resolve(.timedOut)
                    } catch {
                        // The winning explanation or caller cancellation stops this timer.
                    }
                }
                race.install(tasks: [explanationTask, timeoutTask])
                gate.continuation.yield(())
                gate.continuation.finish()
            }
        } onCancel: {
            race.resolve(.cancelled)
        }

        switch outcome {
        case .explanation(let value):
            let explanation = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !explanation.isEmpty else {
                return failed("Foundation Models returned an empty refusal explanation.")
            }
            let limit = max(1, maximumCharacters)
            return Self(
                explanation: String(explanation.prefix(limit)),
                explanationGenerationFailed: false,
                explanationFailureMessage: nil,
                explanationWasTruncated: explanation.count > limit
            )
        case .failure(let message):
            return failed(message)
        case .timedOut:
            return failed("Refusal explanation generation timed out.")
        case .cancelled:
            return failed("Refusal explanation generation was cancelled.")
        }
    }

    /// Creates a failed explanation trace with a bounded diagnostic and no explanation text.
    private static func failed(_ message: String) -> Self {
        Self(
            explanation: nil,
            explanationGenerationFailed: true,
            explanationFailureMessage: boundedFailureMessage(message),
            explanationWasTruncated: false
        )
    }

    /// Limits saved generation-failure diagnostics to the configured character budget.
    private static func boundedFailureMessage(_ message: String) -> String {
        String(message.prefix(maximumFailureMessageCharacters))
    }
}

@available(macOS 27.0, *)
private enum EvaluationRefusalExplanationOutcome: Sendable {
    case explanation(String)
    case failure(String)
    case timedOut
    case cancelled
}

@available(macOS 27.0, *)
private final class EvaluationRefusalExplanationRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<EvaluationRefusalExplanationOutcome, Never>?
    private var tasks: [Task<Void, Never>] = []
    private var resolvedOutcome: EvaluationRefusalExplanationOutcome?

    /// Returns false when cancellation won before the continuation was installed.
    func register(
        _ continuation: CheckedContinuation<EvaluationRefusalExplanationOutcome, Never>
    ) -> Bool {
        lock.lock()
        if let resolvedOutcome {
            lock.unlock()
            continuation.resume(returning: resolvedOutcome)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    /// Registers the race tasks under the lock, cancelling them immediately if an outcome already won.
    func install(tasks: [Task<Void, Never>]) {
        lock.lock()
        if resolvedOutcome != nil {
            lock.unlock()
            tasks.forEach { $0.cancel() }
            return
        }
        self.tasks = tasks
        lock.unlock()
    }

    /// Accepts only the first outcome, cancels the competing tasks, and resumes an installed continuation exactly once.
    func resolve(_ outcome: EvaluationRefusalExplanationOutcome) {
        let continuation: CheckedContinuation<EvaluationRefusalExplanationOutcome, Never>?
        let tasks: [Task<Void, Never>]

        lock.lock()
        guard resolvedOutcome == nil else {
            lock.unlock()
            return
        }
        resolvedOutcome = outcome
        continuation = self.continuation
        self.continuation = nil
        tasks = self.tasks
        self.tasks = []
        lock.unlock()

        tasks.forEach { $0.cancel() }
        continuation?.resume(returning: outcome)
    }
}
