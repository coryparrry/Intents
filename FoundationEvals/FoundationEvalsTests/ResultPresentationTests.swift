import Foundation
import Testing
@testable import FoundationEvals

struct ResultPresentationTests {
    @Test func omittedPartsStayVisibleWhenTheyContainEvidence() {
        var definition = ScenarioDefinition.starter()
        definition.coverage.appFeature = .notApplicable
        definition.coverage.siri = .notApplicable
        let direct = lane(.intentIntegration, .passed)
        let first = ScenarioReportPresentation(run: scenarioRun([direct]), definition: definition)
        #expect(first.includedLanes == [.intentIntegration])
        #expect(first.omittedLanes == [.appFeature, .siri])

        let contradictory = ScenarioReportPresentation(
            run: scenarioRun([direct, lane(.siri, .failed)]), definition: definition
        )
        #expect(contradictory.includedLanes.contains(.siri))
        #expect(contradictory.outcome(for: .siri) == .failed)
    }

    @Test func optionalFailureDoesNotRewriteSavedOverallOutcome() {
        var definition = ScenarioDefinition.starter()
        definition.coverage.siri = .optional
        let run = scenarioRun([lane(.intentIntegration, .passed), lane(.siri, .failed)])
        let presentation = ScenarioReportPresentation(run: run, definition: definition)
        #expect(presentation.run.outcome == .passed)
        #expect(presentation.outcome(for: .siri) == .failed)
        #expect(presentation.headline.contains("passed"))
    }

    @Test func missingAndIncompleteRequiredPartsNeverShowAPass() {
        let definition = ScenarioDefinition.starter()
        let missing = ScenarioReportPresentation(run: scenarioRun([]), definition: definition)
        #expect(missing.includedLanes.contains(.siri))
        #expect(missing.outcome(for: .siri) == .notObserved)
        let mixed = ScenarioReportPresentation(
            run: scenarioRun([lane(.siri, .passed), lane(.siri, .notObserved)]), definition: definition
        )
        #expect(mixed.outcome(for: .siri) == .notObserved)
        #expect(!mixed.summary(for: .siri).contains("matched"))
        let skipped = ScenarioReportPresentation(
            run: scenarioRun([lane(.siri, .passed), lane(.siri, .notApplicable)]), definition: definition
        )
        #expect(skipped.outcome(for: .siri) == .notObserved)
    }

    @Test func archivedRunWithoutDefinitionDoesNotHideMissingContext() {
        let presentation = ScenarioReportPresentation(run: scenarioRun([lane(.intentIntegration, .passed)]), definition: nil)
        #expect(presentation.includedLanes == ScenarioLane.allCases)
        #expect(presentation.omittedLanes.isEmpty)
        #expect(presentation.outcome(for: .siri) == .notObserved)
    }

    @Test func basicResultsExplainTheirLimitedProof() {
        var definition = ScenarioDefinition.starter()
        definition.schemaVersion = ScenarioDefinition.reusableSchemaVersion
        definition.checkMode = .basic
        definition.requiredClaims = [.executionCompleted]
        let run = scenarioRun([lane(.intentIntegration, .passed)])
        let executionOnly = ScenarioReportPresentation(run: run, definition: definition)
        #expect(executionOnly.summary(for: .intentIntegration).contains("Returned values and changes inside the app were not verified"))
        definition.requiredClaims?.append(.returnedValueChecked)
        let returnedValue = ScenarioReportPresentation(run: run, definition: definition)
        #expect(returnedValue.summary(for: .intentIntegration).contains("returned value matched"))
        #expect(returnedValue.summary(for: .intentIntegration).contains("Changes inside the app were not verified"))
    }

    @Test func cancellationIsExplainedWithoutClaimingACheckFailed() {
        var run = scenarioRun([])
        run.executionStatus = .cancelled
        run.outcome = .notObserved
        let presentation = ScenarioReportPresentation(run: run, definition: nil)
        #expect(presentation.headline.contains("stopped"))
        #expect(presentation.nextStep.contains("run this test again"))
    }

    @Test func perfectScoredPassRateDoesNotHideIncompleteEvaluation() {
        var run = evaluationRun()
        run.plannedSampleCount = 3
        #expect(run.passRate == 1)
        #expect(RunReportPresentation(run: run).headline.contains("incomplete"))
        #expect(RunReportPresentation(run: run).nextStep.contains("new run"))
    }

    @Test func unscoredAndUnavailableAssessmentsNeedAttention() {
        var run = evaluationRun()
        run.results[0].status = .unscored
        #expect(RunReportPresentation(run: run).attentionCount == 1)
        #expect(!RunReportPresentation(run: run).headline.contains("passed"))
        run.results[0].status = .passed
        run.selectedAssessmentID = UUID()
        #expect(RunReportPresentation(run: run).attentionCount == 1)
        #expect(!RunReportPresentation(run: run).headline.contains("passed"))
    }

    @Test func recordedErrorsRemainVisibleEvenWithAScore() {
        var run = evaluationRun()
        run.results[0].judgeErrorMessage = "The scoring service did not finish."
        #expect(RunReportPresentation(run: run).attentionCount == 1)
        #expect(RunReportPresentation(run: run).headline.contains("attention"))
    }

    @Test func evaluationCancellationAndEmptyResultsNeverClaimSuccess() {
        var run = evaluationRun()
        run.cancelled = true
        #expect(RunReportPresentation(run: run).headline.contains("cancelled"))
        run.cancelled = false
        run.results = []
        #expect(RunReportPresentation(run: run).headline.contains("No responses"))
    }

    private func lane(_ lane: ScenarioLane, _ outcome: ScenarioOutcome) -> ScenarioLaneResult {
        .init(caseID: UUID(), attempt: 1, lane: lane, executionStatus: .completed,
              outcome: outcome, startedAt: .now, completedAt: .now)
    }

    private func scenarioRun(_ results: [ScenarioLaneResult]) -> ScenarioRun {
        let invocation = ScenarioInvocationIdentity(
            id: UUID(), nonce: "presentation-fixture", issuedAt: .now,
            testIdentity: .init(bundleIdentifier: "dev.example.Tests", className: "Tests", methodName: "testAction"),
            harnessVersion: ScenarioInvocationIdentity.currentHarnessVersion,
            destinationIdentifier: "fixture", scenarioDigest: "fixture", resultBundleIdentity: "fixture",
            appProduct: nil, testProduct: nil
        )
        return .init(
            id: invocation.id, scenarioID: UUID(), scenarioVersion: 1, scenarioDigest: "fixture",
            invocation: invocation, startedAt: .now, completedAt: .now,
            environment: .init(xcodeVersion: "Test", sdkVersion: "Test", deviceModel: "Test Mac",
                               operatingSystem: "Test OS", languageCode: "en", regionCode: "GB",
                               timeZoneIdentifier: "Europe/London", executedAt: .now),
            executionStatus: .completed, outcome: .passed, laneResults: results,
            linkedFeatureRunID: nil, importedAt: .now
        )
    }

    private func evaluationRun() -> EvaluationRun {
        let sample = EvaluationSampleResult(
            caseID: UUID(), caseName: "Test response", repetition: 1, prompt: "Prompt",
            expected: "Expected", response: "Expected", status: .passed, score: 4, rationale: "Matched",
            durationMilliseconds: 100, usage: EvaluationUsage(), errorCategory: nil, errorMessage: nil
        )
        return .init(
            id: UUID(), suiteID: UUID(), suiteName: "Test suite", suiteVersion: "v1",
            instructions: "Instructions", criteria: "Rubric", scoringMode: .modelJudge,
            repetitions: 1, judgePromptVersion: "judge-v1", judgePassingScore: 3, plannedSampleCount: 1,
            startedAt: .now, completedAt: .now, cancelled: false, terminationReason: nil,
            environment: .init(operatingSystem: "Test OS", locale: "en_GB", model: "Test model", modelContextSize: 4096),
            attachments: [], results: [sample]
        )
    }
}
