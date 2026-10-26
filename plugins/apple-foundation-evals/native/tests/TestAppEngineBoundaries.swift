import Foundation
import FoundationModels

@main
struct AppEngineBoundaryTests {
    /// Runs standalone engine regressions without requiring model inference or network access.
    static func main() async throws {
        if #available(macOS 27.0, *) {
            await unsupportedProvidersStopBeforeEvaluation()
            sharedTimingPreservesSignedDurations()
            try transcriptCaptureAndRestorationPreserveEvidence()
            sharedAnalysisPreservesLimitsAndMarkdown()
            try await referenceBoundsPreserveUnicode()
            print("Native app engine boundaries: provider admission, signed timing, and Unicode passed")
        } else {
            print("Native app engine boundaries: skipped; requires macOS 27")
        }
    }

    /// Preserves native transcript storage and restoration after removing unused feedback/export APIs.
    @available(macOS 27.0, *)
    private static func transcriptCaptureAndRestorationPreserveEvidence() throws {
        let transcript = Transcript(entries: [
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "Prompt"))])),
            .response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: "Answer"))]))
        ])
        let trace = EvaluationTranscriptTrace.capture(transcript, outcome: .success)
        let persisted = try JSONEncoder().encode(trace)
        let restored = try JSONDecoder().decode(EvaluationTranscriptTrace.self, from: persisted)
        precondition(restored == trace && restored.entryCount == 2)
        let roundTrip = try restored.restoredTranscript()
        precondition(roundTrip == transcript)
        let omitted = EvaluationTranscriptTrace.capture(transcript, outcome: .failure, maximumBytes: 1)
        precondition(omitted.transcriptJSON == nil && omitted.outcome == .failure && omitted.omissionReason != nil)
        do {
            _ = try omitted.restoredTranscript()
            preconditionFailure("Omitted captures must remain unavailable")
        } catch EvaluationTranscriptArchiveError.transcriptUnavailable { }
    }

    /// Verifies direct runner admission rejects every imported unsupported provider before sessions, tools, or live output begin.
    @available(macOS 27.0, *)
    private static func unsupportedProvidersStopBeforeEvaluation() async {
        for provider in EvaluationModelProvider.allCases where provider != .onDevice {
            var suite = EvaluationSuite()
            suite.modelConfiguration.provider = provider
            suite.scoringMode = .exactMatch
            suite.repetitions = 2
            suite.cases = [
                EvaluationCase(name: "First", prompt: "Reply READY", expected: "READY"),
                EvaluationCase(name: "Second", prompt: "Reply READY", expected: "READY")
            ]
            precondition(AppEngineValidation.validationIssue(for: suite, includeModelReadiness: false)
                == "Only the on-device Apple Foundation Model is supported.")
            let run = await EvaluationRunner().run(
                id: UUID(), suiteRevision: "provider-admission", startedAt: Date(), suite: suite, images: [],
                liveResponse: { _ in preconditionFailure("Unsupported providers must never emit live output") },
                progress: { result, completed, total in
                    precondition(completed == 1 && total == 4)
                    precondition(result.errorCategory == "invalidConfiguration")
                }
            )
            precondition(run.results.count == 1 && run.plannedSampleCount == 4)
            precondition(run.terminationReason == "invalidConfiguration" && !run.cancelled)
            let sample = run.results[0]
            precondition(sample.errorMessage == "Only the on-device Apple Foundation Model is supported.")
            precondition(sample.response.isEmpty && sample.durationMilliseconds == 0)
            precondition(sample.workflowTrace == nil && sample.featureTrace == nil)
            precondition(sample.usage.inputTokens == 0 && sample.usage.outputTokens == 0)
            precondition(run.execution?.configuration.provider == provider)
        }
    }

    /// Verifies all signed monotonic conversions and the workflow recorder's distinct nonnegative evidence policy.
    @available(macOS 27.0, *)
    private static func sharedTimingPreservesSignedDurations() {
        let origin = ContinuousClock.now
        let cases: [(Duration, Double)] = [
            (.zero, 0), (.milliseconds(1_250), 1_250), (.milliseconds(-1_250), -1_250),
            (.nanoseconds(125_000), 0.125), (.nanoseconds(-125_000), -0.125)
        ]
        for (duration, expected) in cases {
            precondition(abs(origin.evaluationMilliseconds(to: origin.advanced(by: duration)) - expected) < 0.000_000_001)
        }
        let recorder = EvaluationWorkflowRecorder(origin: origin)
        let reversed = recorder.begin(kind: .preparation, title: "Reversed", at: origin.advanced(by: .milliseconds(-5)))
        recorder.finish(reversed, at: origin.advanced(by: .milliseconds(-10)))
        let positive = recorder.begin(kind: .generation, title: "Positive", at: origin.advanced(by: .milliseconds(5)))
        recorder.finish(positive, at: origin.advanced(by: .milliseconds(7)))
        let spans = recorder.snapshot().spans
        precondition(spans[0].startOffsetMilliseconds == 0 && spans[0].durationMilliseconds == 0)
        precondition(spans[1].startOffsetMilliseconds == 5 && spans[1].durationMilliseconds == 2)
    }

    /// Keeps both targets' report bytes and the 100-sample planning boundary stable.
    @available(macOS 27.0, *)
    private static func sharedAnalysisPreservesLimitsAndMarkdown() {
        let current = UUID(), candidate = UUID()
        precondition(EvaluationExperimentAnalyzer.balancedOrder(
            currentID: current, candidateID: candidate, caseCount: 20, repetitions: 5).count == 200)
        precondition(EvaluationExperimentAnalyzer.balancedOrder(
            currentID: current, candidateID: candidate, caseCount: 101, repetitions: 1).isEmpty)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let report = EvaluationReleaseCheckEvaluator.projectReport(projectID: id, suites: [])
        let expected = """
        # Project release check passed

        No suites are currently required for this project.

        - Project: `00000000-0000-0000-0000-000000000001`
        - Exit status: `0`

        ## Required suites

        - None configured
        """
        precondition(EvaluationReleaseCheckEvaluator.projectMarkdown(report) == expected)
        precondition(EvaluationReleaseCheckEvaluator.projectMarkdown(report, trailingNewline: true) == expected + "\n")
    }

    /// Verifies reference filename, excerpt, and final-output byte caps preserve complete combining and emoji characters.
    @available(macOS 27.0, *)
    private static func referenceBoundsPreserveUnicode() async throws {
        let combining = "e\u{0301}"
        let family = "👨‍👩‍👧‍👦"
        let exactFilename = String(repeating: "a", count: 55) + family
        for (filename, expected) in [
            ("", ""), (exactFilename, exactFilename), (exactFilename + "x", exactFilename),
            (String(repeating: "a", count: 56) + family, String(repeating: "a", count: 56)),
            (String(repeating: "a", count: 77) + combining + "x", String(repeating: "a", count: 77) + combining),
            (String(repeating: "a", count: 78) + combining, String(repeating: "a", count: 78)),
            ("a" + String(repeating: "\u{0301}", count: 80), "")
        ] {
            let decoded = try JSONDecoder().decode(String.self,
                from: Data(ReferenceLookupTool.filenameJSONLiteral(filename).utf8))
            precondition(decoded == expected && decoded.utf8.count <= 80 && !decoded.contains("�"))
        }
        let escapedFilename = "report\u{0085}\u{2028}\u{2029}\t\r\n\"\\.txt"
        let literal = ReferenceLookupTool.filenameJSONLiteral(escapedFilename)
        let decodedFilename = try JSONDecoder().decode(String.self, from: Data(literal.utf8))
        precondition(decodedFilename == escapedFilename)
        precondition(!literal.contains(where: { $0.isNewline }))
        let text = "reference " + String(repeating: "é", count: 170)
        let attachment = EvaluationAttachment(id: UUID(), name: String(repeating: "\u{0001}", count: 80),
            kind: .text, text: text + family, storedFilename: nil, byteCount: (text + family).utf8.count, sha256: "fixture")
        let index = ReferenceSearchIndex(attachments: [attachment, attachment])
        let results = index.search(query: "reference", maximumResults: 2)
        precondition(results.count == 2 && results.allSatisfy { $0.excerpt == text && $0.excerpt.utf8.count == 350 })
        precondition(index.search(query: "", maximumResults: 2).isEmpty)
        let tool = ReferenceLookupTool(index: index, recorder: ReferenceToolRecorder(maximumCalls: 1))
        let output = try await tool.call(arguments: ReferenceLookupArguments(query: "reference", maximumResults: 2))
        precondition(output.utf8.count <= ReferenceLookupTool.maximumOutputUTF8Bytes && !output.contains("�"))
        precondition(output.hasSuffix("\n[Tool output truncated to its context budget.]"))
    }
}
