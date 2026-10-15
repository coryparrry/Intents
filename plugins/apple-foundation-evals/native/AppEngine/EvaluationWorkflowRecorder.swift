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

    init(origin: ContinuousClock.Instant = .now) {
        self.origin = origin
    }

    var activeParentID: UUID? {
        get { state.withLock { $0.activeParentID } }
        set { state.withLock { $0.activeParentID = newValue } }
    }

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
            startOffsetMilliseconds: Self.milliseconds(from: origin, to: instant),
            durationMilliseconds: 0, status: .succeeded, metadata: metadata
        )
        state.withLock {
            $0.spans.append(span)
            $0.starts[id] = instant
        }
        return id
    }

    func update(_ id: UUID?, metadata: [String: String]) {
        guard let id else { return }
        state.withLock { state in
            guard let index = state.spans.firstIndex(where: { $0.id == id }) else { return }
            state.spans[index].metadata.merge(metadata) { _, new in new }
        }
    }

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
            state.spans[index].durationMilliseconds = Self.milliseconds(from: start, to: instant)
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

    func snapshot() -> EvaluationWorkflowTrace {
        state.withLock { EvaluationWorkflowTrace(spans: $0.spans) }
    }

    static func status(for error: Error) -> EvaluationWorkflowSpanStatus {
        error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled ? .cancelled : .failed
    }

    static func usageMetadata(_ usage: EvaluationUsage) -> [String: String] {
        ["usageSource": "Framework-reported", "inputTokens": String(usage.inputTokens),
         "cachedInputTokens": String(usage.cachedInputTokens), "outputTokens": String(usage.outputTokens),
         "reasoningTokens": String(usage.reasoningTokens)]
    }

    private static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: end).components
        return max(0, Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1_000_000_000_000_000)
    }
}

@available(macOS 27.0, *)
struct EvaluationWorkflowHTTPContext: Sendable {
    var recorder: EvaluationWorkflowRecorder
    var parentID: UUID
    @TaskLocal static var current: EvaluationWorkflowHTTPContext?
}
