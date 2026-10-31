import Foundation
import Testing
@testable import FoundationEvals

struct JSONDocumentTests {
    /// Raw transcript and feedback exports retain their bytes, including formatting and bytes that cannot be parsed as JSON.
    @Test(arguments: [Data("{ \"z\" : 2, \"a\" : \"café\" }\n".utf8), Data([0x00, 0xff, 0x7b, 0x7d])])
    func rawInitializerPreservesPreencodedBytes(_ bytes: Data) {
        #expect(JSONDocument(data: bytes).data == bytes)
    }

    /// Existing run exports still use readable, sorted canonical JSON and round-trip their ISO-8601 dates.
    @Test func runInitializerPreservesCanonicalEncoding() throws {
        let run = run(durationMilliseconds: 12.5)
        let document = try JSONDocument(run: run)
        let restored = try CanonicalJSON.decode(EvaluationRun.self, from: document.data)
        let text = String(decoding: document.data, as: UTF8.self)

        #expect(document.data == (try CanonicalJSON.data(for: run)))
        #expect(text.contains("\n  \"attachments\""))
        #expect(text.contains("2023-11-14T22:13:20Z"))
        #expect(restored.id == run.id)
        #expect(restored.suiteName == run.suiteName)
        #expect(restored.startedAt == run.startedAt)
        #expect(restored.results.first?.durationMilliseconds == 12.5)
    }

    /// Rejects run values that cannot be represented as JSON numbers.
    @Test func runEncodingRejectsNonfiniteValues() {
        let invalidRun = run(durationMilliseconds: .infinity)

        #expect(throws: EncodingError.self) {
            _ = try JSONDocument(run: invalidRun)
        }
    }

    /// Creates a minimal saved run whose duration can exercise valid and nonfinite JSON numeric encoding.
    private func run(durationMilliseconds: Double) -> EvaluationRun {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let sample = EvaluationSampleResult(
            caseID: UUID(), caseName: "Raw export", repetition: 1,
            prompt: "Name a café", expected: "Café", response: "Café",
            status: .passed, score: nil, rationale: nil,
            durationMilliseconds: durationMilliseconds, usage: .init(),
            judgeDurationMilliseconds: nil, judgeUsage: nil,
            errorCategory: nil, errorMessage: nil, judgeErrorCategory: nil, judgeErrorMessage: nil
        )
        return EvaluationRun(
            id: UUID(), suiteID: UUID(), suiteName: "Café exports", suiteVersion: "1",
            instructions: "", criteria: "", scoringMode: .exactMatch, repetitions: 1,
            judgePromptVersion: nil, judgePassingScore: nil, plannedSampleCount: 1,
            startedAt: date, completedAt: date, cancelled: false, terminationReason: nil,
            environment: .init(operatingSystem: "Fixture", locale: "en", model: "Fixture", modelContextSize: 4096),
            attachments: [], results: [sample]
        )
    }
}
