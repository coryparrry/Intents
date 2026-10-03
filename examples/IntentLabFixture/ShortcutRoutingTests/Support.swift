import Foundation

// The routing tests exercise the real intent and fixture-state implementations.
// Model generation is controlled here; these tests do not qualify Siri or the model.
enum SummaryService {
    enum Failure: Error, Equatable { case unavailable }
    nonisolated(unsafe) static var calls: [String] = []
    nonisolated(unsafe) static var shouldFail = false

    static func summarize(_ note: FixtureNote) async throws -> String {
        calls.append(note.id)
        if shouldFail { throw Failure.unavailable }
        return "Summary of \(note.id)"
    }
}

enum FixtureActionContext {
    @TaskLocal static var parentKind: String?
}
