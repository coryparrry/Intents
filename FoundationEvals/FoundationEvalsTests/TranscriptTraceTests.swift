import Foundation
import FoundationModels
import Testing
@testable import FoundationEvals

struct TranscriptTraceTests {
    @Test func realFoundationModelsTranscriptRoundTripsThroughCapturedTrace() throws {
        let prompt = Transcript.Prompt(
            segments: [.text(Transcript.TextSegment(content: "What is the capital of Australia?"))]
        )
        let response = Transcript.Response(
            assetIDs: [],
            segments: [.text(Transcript.TextSegment(content: "Canberra"))]
        )
        let transcript = Transcript(entries: [.prompt(prompt), .response(response)])

        let trace = EvaluationTranscriptTrace.capture(transcript, outcome: .success)
        let persisted = try JSONEncoder().encode(trace)
        let decoded = try JSONDecoder().decode(EvaluationTranscriptTrace.self, from: persisted)
        let restored = try decoded.restoredTranscript()
        let exported = try #require(decoded.exportData)
        let restoredFromExport = try JSONDecoder().decode(Transcript.self, from: exported)

        #expect(decoded == trace)
        #expect(decoded.format == EvaluationTranscriptTrace.formatIdentifier)
        #expect(decoded.entryCount == 2)
        #expect(decoded.encodedByteCount == exported.count)
        #expect(restored == transcript)
        #expect(restoredFromExport == transcript)
    }

    @Test func overLimitTranscriptRecordsAnOmissionInsteadOfPartialAppleJSON() throws {
        let transcript = Transcript(entries: [
            .prompt(Transcript.Prompt(
                segments: [.text(Transcript.TextSegment(content: "A transcript that cannot fit in one byte"))]
            ))
        ])

        let trace = EvaluationTranscriptTrace.capture(
            transcript,
            outcome: .failure,
            maximumBytes: 1
        )

        #expect(trace.outcome == .failure)
        #expect(trace.entryCount == 1)
        #expect(trace.encodedByteCount != nil)
        #expect(trace.exportData == nil)
        #expect(trace.omissionReason?.contains("1-byte capture limit") == true)
        #expect(throws: EvaluationTranscriptArchiveError.self) {
            try trace.restoredTranscript()
        }
    }

    @Test func legacyFeatureTraceDecodingLeavesTranscriptAndConversationUnavailable() throws {
        let json = #"{"customToolCalls":[],"profileEvents":[],"firstContentMilliseconds":12}"#

        let trace = try JSONDecoder().decode(EvaluationFeatureTrace.self, from: Data(json.utf8))

        #expect(trace.firstContentMilliseconds == 12)
        #expect(trace.transcript == nil)
        #expect(trace.conversation == nil)
        #expect(trace.spotlightSearch == nil)
    }

    @Test func feedbackDraftCoversEveryPublicFoundationModelsIssueCategory() {
        #expect(EvaluationFeedbackSentiment.allCases.count == LanguageModelFeedback.Sentiment.allCases.count)
        #expect(EvaluationFeedbackIssueCategory.allCases.count == LanguageModelFeedback.Issue.Category.allCases.count)
    }

    @Test func feedbackAttachmentIsGeneratedFromTheRestoredTranscript() async throws {
        let transcript = Transcript(entries: [
            .prompt(Transcript.Prompt(
                segments: [.text(Transcript.TextSegment(content: "Name Australia's capital."))]
            )),
            .response(Transcript.Response(
                assetIDs: [],
                segments: [.text(Transcript.TextSegment(content: "Sydney"))]
            ))
        ])
        let trace = EvaluationTranscriptTrace.capture(transcript, outcome: .success)
        let configuration = EvaluationModelConfiguration(provider: .onDevice)

        let data = try await trace.feedbackAttachment(
            configuration: configuration,
            sentiment: .negative,
            issues: [.init(category: .incorrect, explanation: "The capital is Canberra.")],
            desiredResponseText: "Canberra"
        )
        let json = try JSONSerialization.jsonObject(with: data)

        #expect(data.isEmpty == false)
        #expect(JSONSerialization.isValidJSONObject(json))
    }

    @Test func coreAIFeedbackExportReportsMissingModelResources() async {
        let transcript = Transcript(entries: [
            .prompt(Transcript.Prompt(
                segments: [.text(Transcript.TextSegment(content: "Test prompt"))]
            ))
        ])
        let trace = EvaluationTranscriptTrace.capture(transcript, outcome: .failure)
        let configuration = EvaluationModelConfiguration(provider: .coreAI)

        await #expect(throws: CoreAIModelLoadingError.resourcesPathRequired) {
            try await trace.feedbackAttachment(
                configuration: configuration,
                sentiment: .negative,
                issues: [],
                desiredResponseText: nil
            )
        }
    }

    @Test func desiredFeedbackOutputDraftValidatesDistinctSDKPayloadsAndBounds() throws {
        var draft = EvaluationFeedbackDesiredOutputDraft(
            mode: .generatedContentJSON,
            generatedContentJSON: #"{"answer":"Canberra"}"#
        )
        #expect(draft.validationIssue == nil)
        _ = try draft.generatedContent()

        let entry = Transcript.Entry.response(Transcript.Response(
            assetIDs: [],
            segments: [.text(Transcript.TextSegment(content: "Canberra"))]
        ))
        let desiredTranscript = Transcript(entries: [entry])
        draft.mode = .transcriptJSON
        draft.transcriptJSON = String(
            decoding: try JSONEncoder().encode(desiredTranscript),
            as: UTF8.self
        )
        #expect(draft.validationIssue == nil)
        #expect(try draft.transcriptEntry() == entry)

        draft.transcriptJSON = String(
            decoding: try JSONEncoder().encode(Transcript(entries: [])),
            as: UTF8.self
        )
        #expect(draft.validationIssue?.contains("exactly one response entry; found 0") == true)

        draft.mode = .generatedContentJSON
        draft.generatedContentJSON = "not-json"
        #expect(draft.validationIssue?.contains("valid Foundation Models") == true)

        draft.mode = .responseText
        draft.responseText = String(
            repeating: "A",
            count: EvaluationFeedbackDesiredOutputDraft.maximumCharacters + 1
        )
        #expect(draft.validationIssue?.contains("characters or fewer") == true)
    }
}
