import Foundation
import FoundationModels

@Generable
struct ScenarioGeneratedRequestCandidate {
    @Guide(description: "A concise request a developer may approve for Siri. Preserve the exact user goal and name the target app for safety.")
    var requestText: String

    @Guide(description: "One of: direct, paraphrase, omitted-optional-detail, entity-ambiguity, negation, contextual-reference, localization.")
    var category: String

    @Guide(description: "A short explanation of what this wording varies. Do not claim it predicts Siri behavior.")
    var note: String
}

@Generable
struct ScenarioGeneratedRequestSet {
    var candidates: [ScenarioGeneratedRequestCandidate]
}

struct ScenarioRequestSuggestion: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var requestText: String
    var category: String
    var note: String
    var approved = false
}

enum ScenarioSuggestionError: LocalizedError, Sendable {
    case unavailable(String)
    case noValidCandidates

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .noValidCandidates: "The model returned no distinct, reviewable request candidates."
        }
    }
}

enum ScenarioSuggestionService {
    private static let allowedCategories = Set([
        "direct", "paraphrase", "omitted-optional-detail", "entity-ambiguity",
        "negation", "contextual-reference", "localization"
    ])

    static func generate(for definition: ScenarioDefinition) async throws -> [ScenarioRequestSuggestion] {
        if let unavailable = EvaluationRunner.unavailableMessage(for: SystemLanguageModel.default.availability) {
            throw ScenarioSuggestionError.unavailable(unavailable)
        }
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: Instructions(
                "Generate review candidates for a developer testing their own synthetic App Intent fixture. Never change the approved goal, invent expected outcomes, or imply that a candidate predicts Siri routing."
            )
        )
        let prompt = """
        Approved goal: \(definition.goal.expectedBehavior)
        Approved request: \(definition.goal.requestText)
        Target app bundle: \(definition.target.bundleIdentifier)
        Language: \(definition.goal.languageCode)
        Allowed action identifiers: \(definition.safety.allowedActions.joined(separator: ", "))

        Produce 4 to 7 short, reviewable candidate requests. Include the target app name or an equally explicit app reference. Mutation, purchase, message, deletion, and account actions are forbidden.
        """
        let response = try await session.respond(
            to: prompt,
            generating: ScenarioGeneratedRequestSet.self,
            options: GenerationOptions(maximumResponseTokens: 1_024, toolCallingMode: .disallowed)
        )
        let candidates = validate(response.content.candidates, original: definition.goal.requestText)
        guard !candidates.isEmpty else { throw ScenarioSuggestionError.noValidCandidates }
        return candidates
    }

    static func validate(
        _ candidates: [ScenarioGeneratedRequestCandidate],
        original: String
    ) -> [ScenarioRequestSuggestion] {
        var seen = Set<String>()
        return candidates.prefix(12).compactMap { candidate in
            let text = candidate.requestText.trimmingCharacters(in: .whitespacesAndNewlines)
            let category = candidate.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let note = candidate.note.trimmingCharacters(in: .whitespacesAndNewlines)
            let identity = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard (4...240).contains(text.count), allowedCategories.contains(category), !note.isEmpty,
                  identity != original.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current),
                  seen.insert(identity).inserted else { return nil }
            return .init(requestText: text, category: category, note: note)
        }
    }
}
