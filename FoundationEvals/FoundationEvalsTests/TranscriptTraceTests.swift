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
            desiredOutput: .init(mode: .responseText, responseText: "Canberra")
        )
        let json = try JSONSerialization.jsonObject(with: data)

        #expect(data.isEmpty == false)
        #expect(JSONSerialization.isValidJSONObject(json))
    }

    @Test func feedbackAttachmentSupportsEveryDesiredOutputModeAndDecodesBeforeRestoring() async throws {
        let entry = Transcript.Entry.response(Transcript.Response(
            assetIDs: [], segments: [.text(Transcript.TextSegment(content: "Canberra"))]
        ))
        let transcript = Transcript(entries: [entry])
        let trace = EvaluationTranscriptTrace.capture(transcript, outcome: .success)
        let transcriptJSON = String(decoding: try JSONEncoder().encode(transcript), as: UTF8.self)
        let drafts: [EvaluationFeedbackDesiredOutputDraft] = [
            .init(),
            .init(mode: .responseText, responseText: "  Canberra  "),
            .init(mode: .generatedContentJSON, generatedContentJSON: #"{"answer":"Canberra"}"#),
            .init(mode: .transcriptJSON, transcriptJSON: transcriptJSON)
        ]
        for draft in drafts {
            let data = try await trace.feedbackAttachment(
                configuration: .init(provider: .onDevice), sentiment: nil, issues: [], desiredOutput: draft
            )
            #expect(JSONSerialization.isValidJSONObject(try JSONSerialization.jsonObject(with: data)))
        }

        var unavailable = trace
        unavailable.transcriptJSON = nil
        for draft in [
            EvaluationFeedbackDesiredOutputDraft(mode: .generatedContentJSON, generatedContentJSON: "not-json"),
            EvaluationFeedbackDesiredOutputDraft(mode: .transcriptJSON, transcriptJSON: "{")
        ] {
            do {
                _ = try await unavailable.feedbackAttachment(
                    configuration: .init(provider: .onDevice), sentiment: nil, issues: [], desiredOutput: draft
                )
                Issue.record("Expected desired-output decoding to fail")
            } catch {
                #expect(!(error is EvaluationTranscriptArchiveError))
            }
        }

        // Foundation Models accepts partial generated content; an incomplete object still reaches archive restoration.
        await #expect(throws: EvaluationTranscriptArchiveError.self) {
            try await unavailable.feedbackAttachment(
                configuration: .init(provider: .onDevice), sentiment: nil, issues: [],
                desiredOutput: .init(mode: .generatedContentJSON, generatedContentJSON: "{")
            )
        }
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
                desiredOutput: .init()
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
