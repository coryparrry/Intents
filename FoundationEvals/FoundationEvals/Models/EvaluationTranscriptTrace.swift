import Foundation
import FoundationModels

enum EvaluationTranscriptCaptureOutcome: String, Codable, Equatable, Sendable {
    case success
    case failure
}

/// Optional complete transcript archive with format identity, capture size, and explicit omission evidence.
struct EvaluationTranscriptTrace: Codable, Equatable, Sendable {
    static let maximumEncodedBytes = 4 * 1_024 * 1_024
    static let formatIdentifier = "com.apple.FoundationModels.Transcript+json"

    var format = Self.formatIdentifier
    var outcome: EvaluationTranscriptCaptureOutcome
    var entryCount: Int
    var encodedByteCount: Int?
    var transcriptJSON: Data?
    var omissionReason: String?

    /// Encodes the complete transcript within the byte limit, retaining counts and an omission reason if encoding or admission fails.
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

    /// Restores a Foundation Models transcript after checking the format and requiring captured JSON bytes.
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

    /// Pretty-prints captured JSON with sorted keys, throwing when bytes are absent or invalid.
    func formattedJSONData() throws -> Data {
        guard let transcriptJSON else {
            throw EvaluationTranscriptArchiveError.transcriptUnavailable(omissionReason)
        }
        let object = try JSONSerialization.jsonObject(with: transcriptJSON)
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// Creates feedback attachment data using the draft's desired output, decoding JSON before restoring the session.
    func feedbackAttachment(
        configuration: EvaluationModelConfiguration,
        sentiment: EvaluationFeedbackSentiment?,
        issues: [EvaluationFeedbackIssueDraft],
        desiredOutput: EvaluationFeedbackDesiredOutputDraft
    ) async throws -> Data {
        // Decode first so invalid desired-output JSON takes precedence over archive errors.
        let content: GeneratedContent?
        let entry: Transcript.Entry?
        switch desiredOutput.mode {
        case .generatedContentJSON:
            content = try desiredOutput.generatedContent()
            entry = nil
        case .transcriptJSON:
            content = nil
            entry = try desiredOutput.transcriptEntry()
        case .none, .responseText:
            content = nil
            entry = nil
        }
        let session = try await rehydratedSession(configuration: configuration)
        let sentiment = sentiment?.foundationModelsValue
        let issues = issues.map(\.foundationModelsValue)
        switch desiredOutput.mode {
        case .none:
            return session.logFeedbackAttachment(sentiment: sentiment, issues: issues, desiredResponseText: nil)
        case .responseText:
            return session.logFeedbackAttachment(
                sentiment: sentiment, issues: issues,
                desiredResponseText: desiredOutput.responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        case .generatedContentJSON:
            return session.logFeedbackAttachment(sentiment: sentiment, issues: issues, desiredResponseContent: content)
        case .transcriptJSON:
            return session.logFeedbackAttachment(sentiment: sentiment, issues: issues, desiredOutput: entry)
        }
    }

    /// Restores the transcript with the configured provider, loading local Core AI resources when required.
    private func rehydratedSession(configuration: EvaluationModelConfiguration) async throws -> LanguageModelSession {
        let transcript = try restoredTranscript()
        switch configuration.provider {
        case .onDevice:
            return LanguageModelSession(model: configuration.systemModel, transcript: transcript)
        case .privateCloudCompute:
            return LanguageModelSession(model: PrivateCloudComputeLanguageModel(), transcript: transcript)
        case .customHTTP:
            return LanguageModelSession(
                model: EvaluationHTTPLanguageModel(configuration: configuration.customProviderSettings),
                transcript: transcript
            )
        case .coreAI:
            let loaded = try await CoreAIModelLoader.shared.load(configuration: configuration.coreAISettings)
            return LanguageModelSession(model: loaded.model, transcript: transcript)
        }
    }
}

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

struct EvaluationFeedbackIssueDraft: Equatable, Sendable {
    var category: EvaluationFeedbackIssueCategory
    var explanation: String?

    var foundationModelsValue: LanguageModelFeedback.Issue {
        LanguageModelFeedback.Issue(category: category.foundationModelsValue, explanation: explanation)
    }
}

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

/// Editable desired feedback output, validated according to text, generated-content JSON, or transcript mode.
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

    /// Parses trimmed generated-content JSON, propagating Foundation Models parsing errors.
    func generatedContent() throws -> GeneratedContent {
        try GeneratedContent(json: generatedContentJSON.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Decodes a complete transcript and requires exactly one response entry for use as desired output.
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

    /// Checks that requested output text is nonblank and within the configured character limit.
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

private enum EvaluationFeedbackDesiredOutputDraftError: LocalizedError {
    case expectedOneResponseEntry(actualCount: Int)

    var errorDescription: String? {
        switch self {
        case .expectedOneResponseEntry(let actualCount):
            "Transcript JSON must contain exactly one response entry; found \(actualCount)."
        }
    }
}
