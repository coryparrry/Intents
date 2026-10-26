import Foundation

/// Current streamed text identified by case, repetition, and conversation turn for in-progress display.
struct EvaluationLiveResponse: Sendable, Equatable {
    var caseID: UUID
    var caseName: String
    var repetition: Int
    var turnName: String
    var content: String
}
