import Foundation
import Testing
@testable import FoundationEvals

struct EvaluationTraceTests {
    @Test func legacySampleDecodingLeavesNewTraceFieldsUnavailable() throws {
        let id = UUID()
        let caseID = UUID()
        let json = """
            {
              "id": "\(id.uuidString)",
              "caseID": "\(caseID.uuidString)",
              "caseName": "Legacy case",
              "repetition": 1,
              "prompt": "Question",
              "expected": "Answer",
              "response": "Answer",
              "status": "passed",
              "durationMilliseconds": 42,
              "usage": {
                "inputTokens": 3,
                "cachedInputTokens": 0,
                "outputTokens": 1,
                "reasoningTokens": 0
              },
              "toolCalls": [{
                "toolName": "search_reference_files",
                "callIndex": 1,
                "matchedFiles": ["Reference.txt"],
                "outputCharacterCount": 24,
                "outcome": "completed"
              }]
            }
            """

        let result = try JSONDecoder().decode(EvaluationSampleResult.self, from: Data(json.utf8))

        #expect(result.timing == nil)
        #expect(result.workflowTrace == nil)
        #expect(result.structuredFeatureEvidence == nil)
        #expect(result.toolCalls?.first?.durationMilliseconds == nil)
        #expect(result.durationMilliseconds == 42)
    }

    @Test func measuredTraceFieldsRoundTripWithoutChangingAggregateDuration() throws {
        var result = EvaluationSampleResult(
            caseID: UUID(),
            caseName: "Timed case",
            repetition: 1,
            prompt: "Question",
            effectivePrompt: "Question with context",
            expected: "Answer",
            response: "Answer",
            status: .passed,
            score: nil,
            rationale: "Exact match",
            durationMilliseconds: 30,
            usage: EvaluationUsage(inputTokens: 3, outputTokens: 1),
            judgeDurationMilliseconds: nil,
            judgeUsage: nil,
            errorCategory: nil,
            errorMessage: nil,
            judgeErrorCategory: nil,
            judgeErrorMessage: nil,
            toolCalls: nil,
            timing: EvaluationSampleTiming(
                preparationMilliseconds: 10,
                generationMilliseconds: 20,
                scoringMilliseconds: 2
            )
        )

        result.structuredFeatureEvidence = .init(
            encodedValue: Data(#"{"selectedNoteID":"packing-001"}"#.utf8),
            encodedValueTypeName: "FixtureSummary",
            metadata: ["fixture": "packing-notes-v1"]
        )

        let decoded = try JSONDecoder().decode(
            EvaluationSampleResult.self,
            from: JSONEncoder().encode(result)
        )

        #expect(decoded.durationMilliseconds == 30)
        #expect(decoded.timing?.preparationMilliseconds == 10)
        #expect(decoded.timing?.generationMilliseconds == 20)
        #expect(decoded.timing?.scoringMilliseconds == 2)
        #expect(decoded.structuredFeatureEvidence?.encodedValue == result.structuredFeatureEvidence?.encodedValue)
        #expect(decoded.structuredFeatureEvidence?.encodedValueTypeName == "FixtureSummary")
        #expect(decoded.structuredFeatureEvidence?.metadata == ["fixture": "packing-notes-v1"])
    }

    @Test func referenceToolRecordsMeasuredDurationWithoutPersistingQueryOrOutput() async throws {
        let attachment = EvaluationAttachment(
            id: UUID(),
            name: "Reference.txt",
            kind: .text,
            text: "The confidential answer is ORCHARD.",
            storedFilename: nil,
            byteCount: 35,
            sha256: "fixture"
        )
        let recorder = ReferenceToolRecorder(maximumCalls: 1)
        let tool = ReferenceLookupTool(
            index: ReferenceSearchIndex(attachments: [attachment]),
            recorder: recorder
        )

        _ = try await tool.call(
            arguments: ReferenceLookupArguments(query: "confidential answer", maximumResults: 1)
        )
        let trace = try #require(await recorder.snapshot().first)
        let duration = try #require(trace.durationMilliseconds)
        let encoded = String(decoding: try JSONEncoder().encode(trace), as: UTF8.self)

        #expect(duration >= 0)
        #expect(!encoded.contains("confidential answer"))
        #expect(!encoded.contains("ORCHARD"))
    }

    @Test func rejectedReferenceToolCallStillLeavesSafeTimingEvidence() async throws {
        let recorder = ReferenceToolRecorder(maximumCalls: 1)
        let tool = ReferenceLookupTool(
            index: ReferenceSearchIndex(attachments: []),
            recorder: recorder
        )

        await #expect(throws: (any Error).self) {
            _ = try await tool.call(
                arguments: ReferenceLookupArguments(query: "   ", maximumResults: 1)
            )
        }
        let trace = try #require(await recorder.snapshot().first)
        let duration = try #require(trace.durationMilliseconds)

        #expect(trace.outcome == "rejected")
        #expect(trace.outputCharacterCount == 0)
        #expect(duration >= 0)
    }
}
