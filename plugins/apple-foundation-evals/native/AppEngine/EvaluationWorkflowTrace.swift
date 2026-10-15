import Foundation

/// Stages observed by the app, on a single monotonic clock. This is not a provider's
/// internal inference trace. Older samples deliberately have no workflow trace.
@available(macOS 27.0, *)
struct EvaluationWorkflowTrace: Codable, Sendable {
    var spans: [EvaluationWorkflowSpan]
    var timingSource = "App-observed monotonic clock"
}

@available(macOS 27.0, *)
struct EvaluationWorkflowSpan: Identifiable, Codable, Sendable {
    var id: UUID
    var parentID: UUID?
    var kind: EvaluationWorkflowSpanKind
    var title: String
    var startOffsetMilliseconds: Double
    var durationMilliseconds: Double
    var status: EvaluationWorkflowSpanStatus
    var errorMessage: String? = nil
    var metadata: [String: String] = [:]
}

@available(macOS 27.0, *)
enum EvaluationWorkflowSpanKind: String, Codable, Sendable {
    case sample, preparation, generation, scoring, judge, tool, httpRequest
}

@available(macOS 27.0, *)
enum EvaluationWorkflowSpanStatus: String, Codable, Sendable {
    case succeeded, failed, cancelled
}
