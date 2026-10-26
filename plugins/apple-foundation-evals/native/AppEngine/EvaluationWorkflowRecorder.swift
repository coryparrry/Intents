import Foundation
import Synchronization

/// Shared by the runner and its tools. Synchronous locking keeps observation from
/// adding actor scheduling delays to the recorded start and end boundaries.
@available(macOS 27.0, *)
final class EvaluationWorkflowRecorder: Sendable {
    private struct State: Sendable {
        var spans: [EvaluationWorkflowSpan] = []
        var starts: [UUID: ContinuousClock.Instant] = [:]
        var activeParentID: UUID?
    }

    private let origin: ContinuousClock.Instant
    private let state = Mutex(State())

    /// Sets the monotonic origin used to express every recorded span's relative start time.
    init(origin: ContinuousClock.Instant = .now) {
        self.origin = origin
    }

    var activeParentID: UUID? {
        get { state.withLock { $0.activeParentID } }
        set { state.withLock { $0.activeParentID = newValue } }
    }

    /// Creates an ordered span and retains its monotonic start instant for later completion, returning its new ID.
    @discardableResult
    func begin(
        kind: EvaluationWorkflowSpanKind,
        title: String,
        parentID: UUID? = nil,
        metadata: [String: String] = [:],
        at instant: ContinuousClock.Instant = .now
    ) -> UUID {
        let id = UUID()
        let span = EvaluationWorkflowSpan(
            id: id, parentID: parentID, kind: kind, title: title,
            startOffsetMilliseconds: max(0, origin.evaluationMilliseconds(to: instant)),
            durationMilliseconds: 0, status: .succeeded, metadata: metadata
        )
        state.withLock {
            $0.spans.append(span)
            $0.starts[id] = instant
        }
        return id
    }

    /// Merges metadata into a known span, preferring new values; nil or unknown IDs are ignored.
    func update(_ id: UUID?, metadata: [String: String]) {
        guard let id else { return }
        state.withLock { state in
            guard let index = state.spans.firstIndex(where: { $0.id == id }) else { return }
            state.spans[index].metadata.merge(metadata) { _, new in new }
        }
    }

    /// Completes an open span once with elapsed time, status, error, and merged metadata; repeated or unknown completions are ignored.
    func finish(
        _ id: UUID?,
        status: EvaluationWorkflowSpanStatus = .succeeded,
        errorMessage: String? = nil,
        metadata: [String: String] = [:],
        at instant: ContinuousClock.Instant = .now
    ) {
        guard let id else { return }
        state.withLock { state in
            guard let start = state.starts.removeValue(forKey: id),
                  let index = state.spans.firstIndex(where: { $0.id == id }) else { return }
            state.spans[index].durationMilliseconds = max(0, start.evaluationMilliseconds(to: instant))
            state.spans[index].status = status
            state.spans[index].errorMessage = errorMessage
            state.spans[index].metadata.merge(metadata) { _, new in new }
        }
    }

    /// Finish any still-open app stages when evaluation throws before their end.
    func finishOpenSpans(status: EvaluationWorkflowSpanStatus, errorMessage: String?, excluding excludedID: UUID? = nil,
                         at instant: ContinuousClock.Instant = .now) {
        let ids = state.withLock { $0.starts.keys.filter { $0 != excludedID } }
        for id in ids { finish(id, status: status, errorMessage: errorMessage, at: instant) }
    }

    /// Returns a lock-protected snapshot of all recorded spans, including spans that have not finished.
    func snapshot() -> EvaluationWorkflowTrace {
        state.withLock { EvaluationWorkflowTrace(spans: $0.spans) }
    }

    /// Classifies task cancellation and cancelled URL requests as cancelled spans; other errors produce failed spans.
    static func status(for error: Error) -> EvaluationWorkflowSpanStatus {
        error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled ? .cancelled : .failed
    }

    /// Labels token counts as framework-reported when attaching usage to workflow evidence.
    static func usageMetadata(_ usage: EvaluationUsage) -> [String: String] {
        ["usageSource": "Framework-reported", "inputTokens": String(usage.inputTokens),
         "cachedInputTokens": String(usage.cachedInputTokens), "outputTokens": String(usage.outputTokens),
         "reasoningTokens": String(usage.reasoningTokens)]
    }
}

@available(macOS 27.0, *)
struct EvaluationWorkflowHTTPContext: Sendable {
    var recorder: EvaluationWorkflowRecorder
    var parentID: UUID
    @TaskLocal static var current: EvaluationWorkflowHTTPContext?
}

@available(macOS 27.0, *)
extension ContinuousClock.Instant {
    /// Converts elapsed monotonic time into signed milliseconds for evaluation timing and evidence.
    func evaluationMilliseconds(to end: ContinuousClock.Instant) -> Double {
        let components = duration(to: end).components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
