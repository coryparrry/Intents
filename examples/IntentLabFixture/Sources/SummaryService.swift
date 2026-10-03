import Foundation
import FoundationModels

enum SummaryService {
    static func summarize(_ note: FixtureNote) async throws -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { throw SummaryServiceError.unavailable }
        let session = LanguageModelSession(
            model: model,
            instructions: "Summarize only the supplied synthetic note in one short sentence. Do not add facts."
        )
        return try await session.respond(to: "Title: \(note.title)\nBody: \(note.body)").content
    }
}

enum SummaryServiceError: LocalizedError {
    case unavailable
    var errorDescription: String? { "The on-device language model is unavailable; deterministic intent checks remain usable." }
}
