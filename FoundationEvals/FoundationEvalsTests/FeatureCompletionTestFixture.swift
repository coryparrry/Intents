import Foundation
@testable import FoundationEvals

/// Immutable app-feature output used by runner terminal-status regressions.
enum FeatureCompletionTestFixture {
    static func make() throws -> EvaluationRun {
        let evaluationCase = EvaluationCase(name: "Feature", prompt: "ready", expected: "READY")
        let projectID = UUID()
        let digest = try EvaluationSubjectEvidenceSnapshot.digest(
            instructions: "", cases: [evaluationCase], attachments: []
        )
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
            hardwareModel: "Mac", appBundleIdentifier: "example.FeatureFixture", appVersion: "1",
            featureID: "fixture.feature", featureVersion: "1", protocolMajorVersion: 1, protocolMinorVersion: 0
        )
        return run
    }
}
