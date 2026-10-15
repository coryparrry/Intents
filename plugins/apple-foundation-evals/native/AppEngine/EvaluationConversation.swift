import Foundation

@available(macOS 27.0, *)
enum EvaluationHistoryPolicy: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case keepAll
    case resetBeforeFinal
    case retainRecentCompleteTurns

    var id: Self { self }
}

@available(macOS 27.0, *)
struct EvaluationSetupTurn: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var prompt = ""
}

@available(macOS 27.0, *)
enum EvaluationModelHistoryProjectionPolicy: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case keepAll
    case reset
    case retainRecentCompleteTurns

    var id: Self { self }
}

@available(macOS 27.0, *)
struct EvaluationModelHistoryProjection: Codable, Hashable, Sendable {
    var policy = EvaluationModelHistoryProjectionPolicy.keepAll
    var retainedTurnCount = 2

    var validationIssue: String? {
        if policy == .retainRecentCompleteTurns,
           !(1...EvaluationConversationConfiguration.maximumRetainedTurns).contains(retainedTurnCount) {
            return "Choose between one and \(EvaluationConversationConfiguration.maximumRetainedTurns) model-facing turns to retain."
        }
        return nil
    }
}

@available(macOS 27.0, *)
struct EvaluationConversationConfiguration: Codable, Hashable, Sendable {
    static let maximumSetupTurns = 12
    static let maximumRetainedTurns = 12
    static let maximumPromptCharacters = 32_000
    static let maximumRestoredTranscriptCharacters = 256_000

    var setupTurns: [EvaluationSetupTurn] = []
    var restoredTranscriptJSON: String? = nil
    var historyPolicy = EvaluationHistoryPolicy.keepAll
    var retainedTurnCount = 2
    var modelHistoryProjection: EvaluationModelHistoryProjection? = nil

    var validationIssue: String? {
        if setupTurns.count > Self.maximumSetupTurns {
            return "Keep each case to \(Self.maximumSetupTurns) setup turns or fewer."
        }
        if Set(setupTurns.map(\.id)).count != setupTurns.count {
            return "Every setup turn needs a unique ID."
        }
        if setupTurns.contains(where: { $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Every setup turn needs a prompt."
        }
        if setupTurns.contains(where: { $0.prompt.count > Self.maximumPromptCharacters }) {
            return "Setup prompts must contain \(Self.maximumPromptCharacters) characters or fewer."
        }
        if let restoredTranscriptJSON,
           restoredTranscriptJSON.count > Self.maximumRestoredTranscriptCharacters {
            return "Restored transcript JSON must contain \(Self.maximumRestoredTranscriptCharacters) characters or fewer."
        }
        if historyPolicy == .retainRecentCompleteTurns,
           !(1...Self.maximumRetainedTurns).contains(retainedTurnCount) {
            return "Choose between one and \(Self.maximumRetainedTurns) recent turns to retain."
        }
        if let issue = modelHistoryProjection?.validationIssue {
            return issue
        }
        if let restoredTranscriptJSON,
           !restoredTranscriptJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           (try? EvaluationConversationTranscriptCodec.decode(restoredTranscriptJSON)) == nil {
            return "Restored transcript JSON must be a Foundation Models transcript export."
        }
        return nil
    }

    var textCharacterCount: Int {
        setupTurns.reduce(0) { $0 + $1.prompt.count } + (restoredTranscriptJSON?.count ?? 0)
    }
}

@available(macOS 27.0, *)
enum EvaluationConversationTurnKind: String, Codable, Sendable {
    case setup
    case evaluation
}

@available(macOS 27.0, *)
struct EvaluationConversationTurnTrace: Codable, Sendable {
    var id: UUID
    var kind: EvaluationConversationTurnKind
    var prompt: String
    var effectivePrompt: String?
    var response: String?
    var durationMilliseconds: Double
    var usage: EvaluationUsage?
    var errorCategory: String?
    var errorMessage: String?
    var refusal: EvaluationRefusalTrace? = nil
}

@available(macOS 27.0, *)
struct EvaluationConversationTrace: Codable, Sendable {
    var restoredEntryCount = 0
    var historyPolicy = EvaluationHistoryPolicy.keepAll
    var retainedTurnCount: Int? = nil
    var historyEntryCountBeforeFinal = 0
    var historyEntryCountAfterPolicy = 0
    var modelHistoryProjection: EvaluationModelHistoryProjection? = nil
    var modelFacingHistoryEntryCountBeforeFinal: Int? = nil
    var turns: [EvaluationConversationTurnTrace] = []
}
