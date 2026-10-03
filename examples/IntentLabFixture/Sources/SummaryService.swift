import Foundation
import FoundationModels
import IntentLabContracts

enum SummaryService {
    static func summarize(
        _ note: FixtureNote,
        resolvedParameters: [String: IntentLabValue] = [:]
    ) async throws -> String {
        let action = FixtureTestSupport.beginProductionService(
            note: note,
            resolvedParameters: resolvedParameters
        )
        do {
            let model = SystemLanguageModel.default
            guard case .available = model.availability else { throw SummaryServiceError.unavailable }
            let session = LanguageModelSession(
                model: model,
                instructions: "Summarize only the supplied synthetic note in one short sentence. Do not add facts."
            )
            let summary = try await session.respond(to: "Title: \(note.title)\nBody: \(note.body)").content
            FixtureTestSupport.finishProductionService(action)
            return summary
        } catch {
            FixtureTestSupport.finishProductionService(action, error: error)
            throw error
        }
    }
}

enum SummaryServiceError: LocalizedError {
    case unavailable
    var errorDescription: String? { "The on-device language model is unavailable; deterministic intent checks remain usable." }
}
