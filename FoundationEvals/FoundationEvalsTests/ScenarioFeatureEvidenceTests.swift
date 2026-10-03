import Foundation
import Testing
@testable import FoundationEvals

struct ScenarioFeatureEvidenceTests {
    @Test(arguments: ["cancelled", "terminated", "partial", "unscored", "error"])
    func ineligibleRunsRetainObservationsWithoutClaimingCompletion(reason: String) throws {
        var (definition, run) = try FeatureCompletionTestFixture.make()
        switch reason {
        case "cancelled": run.cancelled = true
        case "terminated": run.terminationReason = "developerRunner:disconnected"
        case "partial": run.plannedSampleCount = 2
        case "unscored": run.results[0].status = .unscored
        default: run.results[0].status = .error
        }
        definition.assertions = [FeatureCompletionTestFixture.responseAssertion]
        #expect(!ScenarioFeatureEvidence.isEligible(run, for: definition))
        let result = ScenarioFeatureEvidence.laneResult(from: run, definition: definition)
        #expect(result.executionStatus == .invalidEvidence)
        #expect(result.outcome == .notObserved)
        #expect(result.assertionResults.isEmpty)
        #expect(result.observations["feature.response"] == .string("READY"))
        #expect(result.observations["feature.runID"] == .string(run.id.uuidString))
        #expect(result.observations["feature.resultCount"] == .integer(1))
        #expect(result.diagnostic == run.terminationSummary)
    }

    @Test(arguments: ["passed", "businessFailure", "assertionFailure", "semanticReview"])
    func eligibleRunsPreserveBusinessAndAssertionOutcomes(kind: String) throws {
        var (definition, run) = try FeatureCompletionTestFixture.make()
        definition.assertions = [FeatureCompletionTestFixture.responseAssertion]
        var expected: ScenarioOutcome = .passed
        switch kind {
        case "businessFailure":
            run.results[0].status = .failed
            expected = .failed
        case "assertionFailure":
            definition.assertions[0].expectedValue = .string("WRONG")
            expected = .failed
        case "semanticReview":
            definition.assertions[0].kind = .semanticRubric
            expected = .needsReview
        default: break
        }
        #expect(ScenarioFeatureEvidence.isEligible(run, for: definition))
        let result = ScenarioFeatureEvidence.laneResult(from: run, definition: definition)
        #expect(result.executionStatus == .completed)
        #expect(result.outcome == expected)
        let evaluated = ScenarioResultEvaluator.evaluate(
            definition: definition, lane: .appFeature,
            observations: result.observations, executionStatus: .completed
        )
        try #require(result.assertionResults.count == evaluated.1.count)
        var expectedAssertions = evaluated.1
        // Each evaluation creates fresh presentation row IDs. Preserve full
        // equality for assertion identity, verdict, observed value, and message.
        for index in expectedAssertions.indices {
            expectedAssertions[index].id = result.assertionResults[index].id
        }
        #expect(result.assertionResults == expectedAssertions)
        #expect(result.observations["feature.metadata.key"] == .string("value"))
        #expect(result.observations["feature.encodedValue"] == .string(Data("READY".utf8).base64EncodedString()))
        #expect(result.observations["feature.encodedValueType"] == .string("String"))
        #expect(result.observations["feature.passRate"] == .number(kind == "businessFailure" ? 0 : 1))
    }
}

/// Shared immutable run fixture for feature evidence and terminal status regression tests.
enum FeatureCompletionTestFixture {
    static var responseAssertion: ScenarioAssertion {
        .init(kind: .returnedField, observationKey: "feature.response", expectedValue: .string("READY"),
              explanation: "Return READY", applicableLanes: [.appFeature])
    }

    static func make() throws -> (ScenarioDefinition, EvaluationRun) {
        let evaluationCase = EvaluationCase(name: "Feature", prompt: "ready", expected: "READY")
        let projectID = UUID()
        let digest = try EvaluationSubjectEvidenceSnapshot.digest(
            instructions: "", cases: [evaluationCase], attachments: []
        )
        var definition = ScenarioDefinition.starter(projectID: projectID)
        definition.actionRequirements = nil
        definition.directControl.linkedFeatureID = "fixture.feature"
        definition.directControl.linkedFeatureSubjectDigest = digest
        let sample = EvaluationSampleResult(
            caseID: evaluationCase.id, caseName: evaluationCase.name, repetition: 1,
            prompt: evaluationCase.prompt, expected: "READY", response: "READY", status: .passed,
            score: nil, rationale: nil, durationMilliseconds: 1, usage: EvaluationUsage(),
            judgeDurationMilliseconds: nil, judgeUsage: nil, errorCategory: nil, errorMessage: nil,
            judgeErrorCategory: nil, judgeErrorMessage: nil,
            structuredFeatureEvidence: .init(encodedValue: Data("READY".utf8), encodedValueTypeName: "String",
                                             metadata: ["key": "value"])
        )
        var run = EvaluationRun(
            id: UUID(), suiteID: UUID(), suiteName: "Feature", suiteVersion: "1", instructions: "",
            criteria: "READY", scoringMode: .exactMatch, repetitions: 1, judgePromptVersion: nil,
            judgePassingScore: nil, plannedSampleCount: 1, plannedCases: [evaluationCase],
            startedAt: Date(timeIntervalSince1970: 1), completedAt: Date(timeIntervalSince1970: 2),
            cancelled: false, terminationReason: nil,
            environment: .init(operatingSystem: "Test", locale: "en_GB", model: "Test", modelContextSize: 1),
            attachments: [], results: [sample]
        )
        run.projectID = projectID
        run.subjectEvidence = .init(instructions: "", cases: [evaluationCase], attachments: [], digest: digest)
        run.developerExecution = .init(
            runnerID: UUID(), runnerName: "Fixture", platform: "macOS", operatingSystem: "macOS 27",
            hardwareModel: "Mac", appBundleIdentifier: definition.target.bundleIdentifier, appVersion: "1",
            featureID: "fixture.feature", featureVersion: "1", protocolMajorVersion: 1, protocolMinorVersion: 0
        )
        return (definition, run)
    }
}
