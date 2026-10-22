import Foundation
import FoundationModels

enum EvaluationConversationTranscriptCodec {
    static func decode(_ json: String) throws -> Transcript {
        let data = Data(json.utf8)
        do {
            return try JSONDecoder().decode(Transcript.self, from: data)
        } catch let transcriptError {
            do {
                return try JSONDecoder().decode(EvaluationTranscriptTrace.self, from: data).restoredTranscript()
            } catch {
                throw EvaluationConversationError.invalidRestoredTranscript(transcriptError.localizedDescription)
            }
        }
    }
}

enum EvaluationConversationError: LocalizedError {
    case invalidRestoredTranscript(String)

    var errorDescription: String? {
        switch self {
        case .invalidRestoredTranscript(let detail):
            "The restored transcript JSON is invalid: \(detail)"
        }
    }
}

enum EvaluationConversationRuntime {
    static func makeSession<Model: LanguageModel>(
        model: Model,
        tools: [any Tool],
        instructions: String,
        history: [Transcript.Entry],
        modelHistoryProjection: EvaluationModelHistoryProjection?,
        toolBoundary: EvaluationBuiltinToolBoundary? = nil
    ) -> LanguageModelSession {
        if let toolBoundary {
            let profile = LanguageModelSession.Profile {
                if !instructions.isEmpty {
                    Instructions(instructions)
                }
                tools
            }
            .model(model)
            .modifier(toolBoundary)
            guard let modelHistoryProjection else {
                return LanguageModelSession(profile: profile, history: history)
            }
            return LanguageModelSession(
                profile: profile.historyTransform { history in
                    projectedHistory(history, using: modelHistoryProjection)
                },
                history: history
            )
        }
        guard let modelHistoryProjection else {
            let session = LanguageModelSession(
                model: model,
                tools: tools,
                instructions: instructions.isEmpty ? nil : Instructions(instructions)
            )
            if !history.isEmpty {
                replaceHistory(in: session, with: history)
            }
            return session
        }

        let profile = LanguageModelSession.Profile {
            if !instructions.isEmpty {
                Instructions(instructions)
            }
            tools
        }
        .model(model)
        .historyTransform { history in
            projectedHistory(history, using: modelHistoryProjection)
        }
        return LanguageModelSession(profile: profile, history: history)
    }

    static func restoredHistory(from configuration: EvaluationConversationConfiguration) throws -> [Transcript.Entry] {
        guard let json = configuration.restoredTranscriptJSON,
              !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return Array(try EvaluationConversationTranscriptCodec.decode(json).history)
    }

    static func replaceHistory(in session: LanguageModelSession, with entries: [Transcript.Entry]) {
        var transcript = session.transcript
        transcript.history.removeAll(keepingCapacity: true)
        transcript.history.append(contentsOf: entries)
        session.transcript = transcript
    }

    static func applyHistoryPolicy(
        _ configuration: EvaluationConversationConfiguration,
        to session: LanguageModelSession
    ) -> (before: Int, after: Int) {
        let history = Array(session.transcript.history)
        let retained = retainedHistory(
            history,
            policy: configuration.historyPolicy,
            recentTurnCount: configuration.retainedTurnCount
        )
        replaceHistory(in: session, with: retained)
        return (history.count, retained.count)
    }

    static func retainedHistory(
        _ history: [Transcript.Entry],
        policy: EvaluationHistoryPolicy,
        recentTurnCount: Int
    ) -> [Transcript.Entry] {
        switch policy {
        case .keepAll:
            return history
        case .resetBeforeFinal:
            return []
        case .retainRecentCompleteTurns:
            return completeTurns(in: history)
                .suffix(max(0, recentTurnCount))
                .flatMap { $0 }
        }
    }

    static func projectedHistory(
        _ history: [Transcript.Entry],
        using projection: EvaluationModelHistoryProjection
    ) -> [Transcript.Entry] {
        let partition = conversationHistory(in: history)
        return switch projection.policy {
        case .keepAll:
            history
        case .reset:
            partition.incompleteTurn
        case .retainRecentCompleteTurns:
            partition.completeTurns
                .suffix(max(0, projection.retainedTurnCount))
                .flatMap { $0 }
                + partition.incompleteTurn
        }
    }

    static func modelFacingHistory(
        _ storedHistory: [Transcript.Entry],
        projection: EvaluationModelHistoryProjection?
    ) -> [Transcript.Entry] {
        guard let projection else { return storedHistory }
        // The session applies its transform after appending the new prompt. An
        // unfinished restored prompt must not survive a reset/retention transform
        // merely because evidence was captured just before that append.
        let nextPrompt = Transcript.Entry.prompt(Transcript.Prompt(segments: []))
        return Array(projectedHistory(storedHistory + [nextPrompt], using: projection).dropLast())
    }

    static func completeTurns(in history: [Transcript.Entry]) -> [[Transcript.Entry]] {
        conversationHistory(in: history).completeTurns
    }

    private static func conversationHistory(
        in history: [Transcript.Entry]
    ) -> (completeTurns: [[Transcript.Entry]], incompleteTurn: [Transcript.Entry]) {
        var turns: [[Transcript.Entry]] = []
        var current: [Transcript.Entry]?

        for entry in history {
            switch entry {
            case .prompt:
                current = [entry]
            case .response:
                guard var completed = current else { continue }
                completed.append(entry)
                turns.append(completed)
                current = nil
            default:
                current?.append(entry)
            }
        }
        return (turns, current ?? [])
    }

    static func generateSetupTurn(
        _ prompt: Prompt,
        session: LanguageModelSession,
        suite: EvaluationSuite,
        metadata: [String: any ConvertibleToGeneratedContent],
        onPartial: @Sendable (String) async -> Void = { _ in }
    ) async throws -> EvaluationFeatureResponse {
        var textSuite = suite
        textSuite.features.outputFields = []
        return try await EvaluationFeatureResponse.generate(
            session: session,
            prompt: prompt,
            suite: textSuite,
            metadata: metadata,
            onPartial: onPartial
        )
    }
}
