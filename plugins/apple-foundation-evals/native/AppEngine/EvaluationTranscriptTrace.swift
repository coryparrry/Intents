import Foundation
import FoundationModels

@available(macOS 27.0, *)
enum EvaluationTranscriptCaptureOutcome: String, Codable, Equatable, Sendable {
    case success
    case failure
}

@available(macOS 27.0, *)
struct EvaluationTranscriptTrace: Codable, Equatable, Sendable {
    static let maximumEncodedBytes = 4 * 1_024 * 1_024
    static let formatIdentifier = "com.apple.FoundationModels.Transcript+json"

    var format = Self.formatIdentifier
    var outcome: EvaluationTranscriptCaptureOutcome
    var entryCount: Int
    var encodedByteCount: Int?
    var transcriptJSON: Data?
    var omissionReason: String?

    static func capture(
        _ transcript: Transcript,
        outcome: EvaluationTranscriptCaptureOutcome,
        maximumBytes: Int = Self.maximumEncodedBytes
    ) -> Self {
        do {
            let data = try JSONEncoder().encode(transcript)
            guard data.count <= maximumBytes else {
                return Self(
                    outcome: outcome,
                    entryCount: transcript.count,
                    encodedByteCount: data.count,
                    omissionReason: "The encoded transcript exceeded the \(maximumBytes)-byte capture limit."
                )
            }
            return Self(
                outcome: outcome,
                entryCount: transcript.count,
                encodedByteCount: data.count,
                transcriptJSON: data
            )
        } catch {
            return Self(
                outcome: outcome,
                entryCount: transcript.count,
                encodedByteCount: nil,
                omissionReason: "Foundation Models could not encode this transcript: \(error.localizedDescription)"
            )
        }
    }

    func restoredTranscript() throws -> Transcript {
        guard format == Self.formatIdentifier else {
            throw EvaluationTranscriptArchiveError.unsupportedFormat(format)
        }
        guard let transcriptJSON else {
            throw EvaluationTranscriptArchiveError.transcriptUnavailable(omissionReason)
        }
        return try JSONDecoder().decode(Transcript.self, from: transcriptJSON)
    }

    var exportData: Data? { transcriptJSON }

    func formattedJSONData() throws -> Data {
        guard let transcriptJSON else {
            throw EvaluationTranscriptArchiveError.transcriptUnavailable(omissionReason)
        }
        let object = try JSONSerialization.jsonObject(with: transcriptJSON)
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    func feedbackAttachment(
        configuration: EvaluationModelConfiguration,
        sentiment: EvaluationFeedbackSentiment?,
        issues: [EvaluationFeedbackIssueDraft],
        desiredResponseText: String?
    ) async throws -> Data {
        let session = try await rehydratedSession(configuration: configuration)
        return session.logFeedbackAttachment(
            sentiment: sentiment?.foundationModelsValue,
            issues: issues.map(\.foundationModelsValue),
            desiredResponseText: desiredResponseText
        )
    }

    func feedbackAttachment(
        configuration: EvaluationModelConfiguration,
        sentiment: EvaluationFeedbackSentiment?,
        issues: [EvaluationFeedbackIssueDraft],
        desiredOutput: Transcript.Entry?
    ) async throws -> Data {
        let session = try await rehydratedSession(configuration: configuration)
        return session.logFeedbackAttachment(
            sentiment: sentiment?.foundationModelsValue,
            issues: issues.map(\.foundationModelsValue),
            desiredOutput: desiredOutput
        )
    }

    func feedbackAttachment(
        configuration: EvaluationModelConfiguration,
        sentiment: EvaluationFeedbackSentiment?,
        issues: [EvaluationFeedbackIssueDraft],
        desiredResponseContent: (any ConvertibleToGeneratedContent)?
    ) async throws -> Data {
        let session = try await rehydratedSession(configuration: configuration)
        return session.logFeedbackAttachment(
            sentiment: sentiment?.foundationModelsValue,
            issues: issues.map(\.foundationModelsValue),
            desiredResponseContent: desiredResponseContent
        )
    }

    private func rehydratedSession(configuration: EvaluationModelConfiguration) async throws -> LanguageModelSession {
        let transcript = try restoredTranscript()
        guard configuration.provider == .onDevice else {
            throw RunnerFailure.validation("Only on-device transcripts can be rehydrated.")
        }
        return LanguageModelSession(model: configuration.systemModel, transcript: transcript)
    }
}

@available(macOS 27.0, *)
enum EvaluationTranscriptArchiveError: LocalizedError {
    case unsupportedFormat(String)
    case transcriptUnavailable(String?)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            "Unsupported transcript format: \(format)"
        case .transcriptUnavailable(let reason):
            reason ?? "The transcript was not captured."
        }
    }
}

@available(macOS 27.0, *)
enum EvaluationFeedbackSentiment: String, CaseIterable, Identifiable, Hashable, Sendable {
    case positive
    case neutral
    case negative

    var id: Self { self }

    var title: String { rawValue.capitalized }

    var foundationModelsValue: LanguageModelFeedback.Sentiment {
        switch self {
        case .positive: .positive
        case .neutral: .neutral
        case .negative: .negative
        }
    }
}

@available(macOS 27.0, *)
enum EvaluationFeedbackIssueCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case unhelpful
    case tooVerbose
    case didNotFollowInstructions
    case incorrect
    case stereotypeOrBias
    case suggestiveOrSexual
    case vulgarOrOffensive
    case triggeredGuardrailUnexpectedly

    var id: Self { self }

    var title: String {
        switch self {
        case .unhelpful: "Unhelpful"
        case .tooVerbose: "Too verbose"
        case .didNotFollowInstructions: "Did not follow instructions"
        case .incorrect: "Incorrect"
        case .stereotypeOrBias: "Stereotype or bias"
        case .suggestiveOrSexual: "Suggestive or sexual"
        case .vulgarOrOffensive: "Vulgar or offensive"
        case .triggeredGuardrailUnexpectedly: "Triggered guardrail unexpectedly"
        }
    }

    var foundationModelsValue: LanguageModelFeedback.Issue.Category {
        switch self {
        case .unhelpful: .unhelpful
        case .tooVerbose: .tooVerbose
        case .didNotFollowInstructions: .didNotFollowInstructions
        case .incorrect: .incorrect
        case .stereotypeOrBias: .stereotypeOrBias
        case .suggestiveOrSexual: .suggestiveOrSexual
        case .vulgarOrOffensive: .vulgarOrOffensive
        case .triggeredGuardrailUnexpectedly: .triggeredGuardrailUnexpectedly
        }
    }
}

@available(macOS 27.0, *)
struct EvaluationFeedbackIssueDraft: Equatable, Sendable {
    var category: EvaluationFeedbackIssueCategory
    var explanation: String?

    var foundationModelsValue: LanguageModelFeedback.Issue {
        LanguageModelFeedback.Issue(category: category.foundationModelsValue, explanation: explanation)
    }
}

@available(macOS 27.0, *)
enum EvaluationFeedbackDesiredOutputMode: String, CaseIterable, Identifiable, Sendable {
    case none
    case responseText
    case generatedContentJSON
    case transcriptJSON

    var id: Self { self }

    var title: String {
        switch self {
        case .none: "Not specified"
        case .responseText: "Response text"
        case .generatedContentJSON: "Generated content JSON"
        case .transcriptJSON: "Response from transcript JSON"
        }
    }
}

@available(macOS 27.0, *)
struct EvaluationFeedbackDesiredOutputDraft: Equatable, Sendable {
    static let maximumCharacters = 32_000

    var mode = EvaluationFeedbackDesiredOutputMode.none
    var responseText = ""
    var generatedContentJSON = ""
    var transcriptJSON = ""

    var hasDesiredOutput: Bool { mode != .none && validationIssue == nil }

    var validationIssue: String? {
        switch mode {
        case .none:
            return nil
        case .responseText:
            return textIssue(responseText, label: "Desired response")
        case .generatedContentJSON:
            if let issue = textIssue(generatedContentJSON, label: "Generated content JSON") {
                return issue
            }
            do {
                _ = try generatedContent()
                return nil
            } catch {
                return "Generated content JSON must be valid Foundation Models generated content."
            }
        case .transcriptJSON:
            if let issue = textIssue(transcriptJSON, label: "Transcript JSON") {
                return issue
            }
            do {
                _ = try transcriptEntry()
                return nil
            } catch let error as EvaluationFeedbackDesiredOutputDraftError {
                return error.localizedDescription
            } catch {
                return "Transcript JSON must decode as a complete Foundation Models transcript."
            }
        }
    }

    func generatedContent() throws -> GeneratedContent {
        try GeneratedContent(json: generatedContentJSON.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func transcriptEntry() throws -> Transcript.Entry {
        let json = transcriptJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = try JSONDecoder().decode(Transcript.self, from: Data(json.utf8))
        let responseEntries = transcript.filter { entry in
            if case .response = entry {
                return true
            }
            return false
        }
        guard responseEntries.count == 1, let responseEntry = responseEntries.first else {
            throw EvaluationFeedbackDesiredOutputDraftError.expectedOneResponseEntry(
                actualCount: responseEntries.count
            )
        }
        return responseEntry
    }

    private func textIssue(_ value: String, label: String) -> String? {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(label) cannot be empty."
        }
        if value.count > Self.maximumCharacters {
            return "\(label) must be \(Self.maximumCharacters.formatted()) characters or fewer."
        }
        return nil
    }
}

@available(macOS 27.0, *)
private enum EvaluationFeedbackDesiredOutputDraftError: LocalizedError {
    case expectedOneResponseEntry(actualCount: Int)

    var errorDescription: String? {
        switch self {
        case .expectedOneResponseEntry(let actualCount):
            "Transcript JSON must contain exactly one response entry; found \(actualCount)."
        }
    }
}
