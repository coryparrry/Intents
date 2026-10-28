import Foundation
import Testing
@testable import FoundationEvals

/// Checks the boundary between runner error categories and the content-free telemetry vocabulary.
@MainActor struct TelemetryWorkflowContractTests {
    /// A successful partial or no-op operation remains observable without counting as completed feature adoption.
    @Test func partialCompletionDoesNotCountFeatureAdoption() throws {
        let suite = "TelemetryWorkflowContractTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: TelemetryController.consentKey)
        defaults.set(true, forKey: TelemetryController.diagnosticsConsentKey)
        let client = DiagnosticRecordingClient()
        let recorder = TelemetryController(defaults: defaults,
            configuration: .init(projectToken: "phc_test", host: "https://telemetry.invalid"), makeClient: { _ in client })
        recorder.end(recorder.begin(.batchRun), recordsFeature: false)
        #expect(client.events.contains { $0.properties["outcome"] as? String == "succeeded" })
        #expect(!client.events.contains { $0.name == "intents_feature_used" })
        recorder.end(recorder.begin(.batchRun))
        #expect(client.events.filter { $0.properties["feature"] as? String == "batch_run" }.count == 1)
    }

    /// Uses real runner classification so changes to producer names cannot silently become unexpected diagnostics.
    @Test func runnerNetworkAndInputFailuresKeepTheirDiagnosticCategories() {
        let network = EvaluationRunner.traceError(URLError(.notConnectedToInternet))
        #expect(network.category == "networkFailure")
        #expect(TelemetryFailure.evaluationCategory(network.category) == .network)
        let input = EvaluationRunner.traceError(EvaluationRunner.EvaluationRunnerError.inputTooLarge(tokens: 100, budget: 10))
        #expect(TelemetryFailure.evaluationCategory(input.category) == .validation)
        let judge = EvaluationRunner.traceError(EvaluationRunner.EvaluationRunnerError.judgeInputTooLarge)
        #expect(TelemetryFailure.evaluationCategory(judge.category) == .judge)
        #expect(TelemetryFailure.evaluationCategory("contextSizeExceeded") == .generation)
        #expect(TelemetryFailure.evaluationCategory("private unknown detail") == .unexpected)
    }

    /// Every category that can halt the real runner must retain an actionable diagnostic group.
    @Test func batchStoppingErrorsAreKnown() {
        for category in EvaluationRunner.batchStoppingErrorCategories {
            #expect(TelemetryFailure.evaluationCategory(category) != .unexpected)
        }
    }

    /// New workflow categories pass the final payload filter while arbitrary content remains excluded.
    @Test(arguments: [TelemetryOperation.documentGenerate, .suiteImport, .suiteExport, .reviewSave, .batchRun, .appIntentRun,
        .documentImport, .referenceImport, .datasetImport, .resultExport])
    func newWorkflowPayloadsRemainContentFree(_ operation: TelemetryOperation) throws {
        let feature = try #require(TelemetryFeature(operation: operation))
        let event = TelemetryEvent.operationFinished(operation, UUID(), .succeeded, 12, nil)
        var payload = event.properties
        payload["document_name"] = "private document"
        payload["prompt"] = "private prompt"
        let safe = try #require(TelemetryPayloadFilter.properties(payload, event: event.name))
        #expect(safe["operation"] as? String == operation.rawValue)
        #expect(safe["duration_ms"] as? Int == 12)
        #expect(safe["document_name"] == nil)
        #expect(safe["prompt"] == nil)
        let usage = try #require(TelemetryPayloadFilter.properties(["feature": feature.rawValue,
            "file_path": "/private/content"], event: "intents_feature_used"))
        #expect(usage["feature"] as? String == feature.rawValue)
        #expect(usage["file_path"] == nil)
    }
}
