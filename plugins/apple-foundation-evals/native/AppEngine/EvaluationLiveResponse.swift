import Foundation

@available(macOS 27.0, *)
struct EvaluationLiveResponse: Sendable, Equatable, Encodable {
    var caseID: UUID
    var caseName: String
    var repetition: Int
    var turnName: String
    var content: String
}
