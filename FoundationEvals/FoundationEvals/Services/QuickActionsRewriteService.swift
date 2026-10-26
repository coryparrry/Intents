import Foundation
import FoundationModels

enum QuickActionsRewriteError: LocalizedError, Sendable {
    case unavailable(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .emptyResponse: "The model returned an empty revision."
        }
    }
}

enum QuickActionsPromptCatalog {
    static let primary: [QuickActionsPillAction] = [
        .init(id: "rewrite", title: "Rewrite", systemImage: "sparkles", busyLabel: "Rewriting"),
        .init(id: "grammar", title: "Grammar", systemImage: "textformat", busyLabel: "Fixing grammar")
    ]
    static let additional: [QuickActionsPillAction] = [
        .init(id: "shorten", title: "Shorten", systemImage: "scissors", busyLabel: "Shortening"),
        .init(id: "tone", title: "Change tone", systemImage: "face.smiling", busyLabel: "Changing tone")
    ]

    /// Returns editing instructions for the selected action, using the general clarity rewrite for an unknown action ID.
    static func instructions(for id: String) -> String {
        switch id {
        case "shorten":
            "Rewrite the evaluation prompt below to say the same thing in fewer words. Preserve every requirement, constraint, and expected output detail. Return only the revised prompt."
        case "tone":
            "Rewrite the evaluation prompt below with a clear, direct tone while preserving every requirement, constraint, and expected output detail. Return only the revised prompt."
        case "grammar":
            "Fix the spelling, grammar, and punctuation of the evaluation prompt below without changing its requirements or meaning. Return only the revised prompt."
        case "prompt":
            "Revise the evaluation prompt below according to the editing request. Preserve every requirement that the request does not ask to change. Return only the revised prompt."
        default:
            "Rewrite the evaluation prompt below for clarity and precision. Preserve every requirement, constraint, and expected output detail. Return only the revised prompt."
        }
    }
}

enum QuickActionsRewriteService {
    /// Streams revised prompt snapshots at roughly 100-millisecond intervals and always publishes the final nonempty response.
    /// Uses the on-device model with tools disabled; unavailability, generation failures and cancellation finish the stream with an error.
    /// Terminating the consumer cancels the underlying generation task.
    static func stream(
        request: QuickActionsPillRequest,
        source: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let unavailable = EvaluationRunner.unavailableMessage(
                        for: SystemLanguageModel.default.availability
                    ) {
                        throw QuickActionsRewriteError.unavailable(unavailable)
                    }
                    let session = LanguageModelSession(
                        model: SystemLanguageModel.default,
                        instructions: Instructions(
                            "You revise test-case prompts for an evaluation workbench. Return only the revised prompt text, with no preamble or explanation."
                        )
                    )
                    let editingRequest = request.prompt.map { "\($0)\n\n" } ?? ""
                    let prompt = Prompt {
                        "\(QuickActionsPromptCatalog.instructions(for: request.id))\n\n\(editingRequest)Original evaluation prompt:\n\(source)"
                    }
                    let options = GenerationOptions(
                        samplingMode: nil,
                        temperature: nil,
                        maximumResponseTokens: 1_024,
                        toolCallingMode: .disallowed
                    )
                    let stream = session.streamResponse(to: prompt, options: options)
                    var lastPublication = ContinuousClock.now
                    for try await snapshot in stream {
                        try Task.checkCancellation()
                        let visible = snapshot.content.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !visible.isEmpty, lastPublication.duration(to: .now) >= .milliseconds(100) {
                            continuation.yield(snapshot.content)
                            lastPublication = .now
                        }
                    }
                    let response = try await stream.collect()
                    try Task.checkCancellation()
                    let final = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !final.isEmpty else {
                        throw QuickActionsRewriteError.emptyResponse
                    }
                    continuation.yield(response.content)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
