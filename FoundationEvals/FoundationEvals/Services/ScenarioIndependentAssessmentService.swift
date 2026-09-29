import CryptoKit
import Foundation

/// One saved scenario observation presented to the existing independent judge.
/// References and rubrics stay in this host-only request, never in subject input.
struct ScenarioAssessmentRequest: Sendable {
    var scenarioRunID: UUID
    var laneResult: ScenarioLaneResult
    var assertion: ScenarioAssertion
    var effectiveInput: String
    var verifiedReference: String
    var judgeConfiguration: EvaluationJudgeConfiguration

    var capturedOutput: String? {
        guard case .string(let value)? = laneResult.observations[assertion.observationKey] else { return nil }
        return value
    }
}

/// Retained separately from the subject execution. The embedded assessment is
/// the versioned Evaluation assessment with its complete judge trace.
struct ScenarioIndependentAssessment: Codable, Identifiable, Sendable {
    var id: UUID { assessment.id }
    var scenarioRunID: UUID
    var laneResultID: UUID
    var caseID: UUID
    var lane: ScenarioLane
    var attempt: Int
    var assertionID: UUID
    var observationKey: String
    var verifiedReference: String
    var rubric: String
    var effectiveInput: String
    var rawOutputDigest: String
    var verifiedReferenceDigest: String
    var rubricDigest: String
    var judgePolicyDigest: String
    var judgePolicy: ScenarioJudgePolicySnapshot
    var sourceBindingDigest: String
    var scoringContract: EvaluationScoringContract
    var assessment: EvaluationAssessment
    var availabilityIssue: String?
    /// Captured before judging, with fractional seconds preserved in portable
    /// JSON so a new frozen policy cannot admit a prior verdict.
    var assessmentStartedAt: TimeInterval? = nil

    var sample: EvaluationSampleAssessment? {
        assessment.samples.count == 1 ? assessment.samples.first : nil
    }

    var isScored: Bool {
        guard let sample else { return false }
        return sample.status == .passed || sample.status == .failed
    }

    func portableProjection() throws -> ScenarioSelectedAssessmentProjection {
        let status: ScenarioSelectedAssessmentStatus
        switch sample?.status {
        case .passed: status = .passed
        case .failed: status = .failed
        case .unscored, .error, nil: status = .unscored
        }
        return .init(
            scenarioRunID: scenarioRunID,
            laneResultID: laneResultID,
            caseID: caseID,
            lane: lane,
            attempt: attempt,
            assertionID: assertionID,
            observationKey: observationKey,
            selectedAssessmentID: id,
            status: status,
            rawOutputDigest: rawOutputDigest,
            verifiedReferenceDigest: verifiedReferenceDigest,
            rubricDigest: rubricDigest,
            sourceBindingDigest: sourceBindingDigest,
            scoringContractDigest: ScenarioIndependentAssessmentService.digest(
                try CanonicalJSON.data(for: scoringContract, prettyPrinted: false)
            ),
            judgePolicyDigest: judgePolicyDigest,
            judgePromptVersion: assessment.promptVersion,
            requestedJudgeModelID: assessment.judge.requestedModelID,
            reportedJudgeModelID: assessment.judge.reportedModelID,
            judgeConnectionID: assessment.judge.connectionID
        )
    }

    func portableArtifact() throws -> ScenarioRetainedAssessmentArtifact {
        try ScenarioRetainedAssessmentArtifact.make(
            projection: portableProjection(),
            retainedAssessmentJSON: CanonicalJSON.data(for: self, prettyPrinted: false)
        )
    }
}

struct ScenarioJudgePolicySnapshot: Codable, Sendable {
    var scoringContract: EvaluationScoringContract
    var promptVersion: String
    var passingScore: Int
    var judgeMode: EvaluationJudgeMode
    var connectionID: UUID?
    var connectionDisclosureDigest: String?
    var includeReferenceAttachments: Bool
}

struct ScenarioAssessmentSourceBinding: Codable {
    var scenarioRunID: UUID
    var laneResultID: UUID
    var caseID: UUID
    var lane: ScenarioLane
    var attempt: Int
    var assertionID: UUID
    var observationKey: String
    var rawOutputDigest: String
    var verifiedReferenceDigest: String
    var rubricDigest: String
}

/// A selection changes which retained assessment applies; it does not change
/// the captured response or erase older assessments.
struct ScenarioAssessmentHistory: Codable, Sendable {
    var assessments: [ScenarioIndependentAssessment] = []
    var selections: [Selection] = []

    struct Selection: Codable, Sendable {
        var laneResultID: UUID
        var assertionID: UUID
        var assessmentID: UUID
    }

    mutating func append(_ assessment: ScenarioIndependentAssessment, select: Bool = true) throws {
        guard !assessments.contains(where: { $0.id == assessment.id }) else {
            throw ScenarioAssessmentError.duplicateAssessment
        }
        assessments.append(assessment)
        if select {
            selections.removeAll { $0.laneResultID == assessment.laneResultID && $0.assertionID == assessment.assertionID }
            selections.append(.init(
                laneResultID: assessment.laneResultID,
                assertionID: assessment.assertionID,
                assessmentID: assessment.id
            ))
        }
    }

    mutating func select(_ assessmentID: UUID, for laneResultID: UUID, assertionID: UUID) throws {
        guard assessments.contains(where: {
            $0.id == assessmentID && $0.laneResultID == laneResultID && $0.assertionID == assertionID
        }) else {
            throw ScenarioAssessmentError.unknownAssessment
        }
        selections.removeAll { $0.laneResultID == laneResultID && $0.assertionID == assertionID }
        selections.append(.init(laneResultID: laneResultID, assertionID: assertionID, assessmentID: assessmentID))
    }

    func selected(for laneResultID: UUID, assertionID: UUID) -> ScenarioIndependentAssessment? {
        guard let selection = selections.first(where: {
            $0.laneResultID == laneResultID && $0.assertionID == assertionID
        }) else { return nil }
        return assessments.first {
            $0.id == selection.assessmentID && $0.laneResultID == laneResultID && $0.assertionID == assertionID
        }
    }
}

enum ScenarioAssessmentError: LocalizedError {
    case invalidAssertion
    case duplicateAssessment
    case unknownAssessment

    var errorDescription: String? {
        switch self {
        case .invalidAssertion: "The semantic check does not apply to this captured route."
        case .duplicateAssessment: "This assessment is already retained."
        case .unknownAssessment: "The selected assessment does not belong to this semantic check."
        }
    }
}

/// This adapter only reads completed observations and invokes the same
/// `EvaluationReassessmentService` used by saved feature runs. It has no
/// subject runner, intent executor, or retry path into the app action.
enum ScenarioIndependentAssessmentService {
    static func assess(
        _ request: ScenarioAssessmentRequest,
        resolvedJudge: EvaluationResolvedJudgeConnection?,
        service: EvaluationReassessmentService = EvaluationReassessmentService()
    ) async throws -> ScenarioIndependentAssessment {
        let assessmentStartedAt = Date().timeIntervalSince1970
        guard request.assertion.kind == .semanticRubric,
              request.assertion.applies(to: request.laneResult.lane) else {
            throw ScenarioAssessmentError.invalidAssertion
        }

        switch request.assertion.expectedValue {
        case .string(let reference) where reference == request.verifiedReference: break
        case nil where request.verifiedReference.isEmpty: break
        default: throw ScenarioAssessmentError.invalidAssertion
        }

        let response = request.capturedOutput ?? ""
        let rubric = request.assertion.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        let criteria = rubric.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard (1...4).contains(criteria.count) else {
            throw ScenarioAssessmentError.invalidAssertion
        }
        let evaluationCase = EvaluationCase(
            id: request.laneResult.caseID,
            name: request.laneResult.lane.title,
            prompt: request.effectiveInput,
            expected: request.verifiedReference
        )
        var suite = EvaluationSuite()
        suite.id = request.scenarioRunID
        suite.name = "Scenario semantic assessment"
        suite.instructions = "Assess the captured app response against the frozen host criteria."
        suite.criteria = rubric
        suite.scoringMode = .modelJudge
        suite.repetitions = 1
        suite.cases = [evaluationCase]
        suite.judgeConfiguration = request.judgeConfiguration
        let contract = try EvaluationScoringContract(suite: suite)

        let policyJudge: EvaluationResolvedJudgeConnection?
        let availabilityIssue: String?
        if request.judgeConfiguration.mode != .connection {
            policyJudge = nil
            availabilityIssue = "Choose an independent judge connection for semantic assessment."
        } else if let resolvedJudge,
                  request.judgeConfiguration.connectionID == resolvedJudge.connection.id,
                  request.judgeConfiguration.hasCurrentExternalEvidenceApproval(for: resolvedJudge.connection) {
            policyJudge = resolvedJudge
            availabilityIssue = nil
        } else {
            policyJudge = nil
            availabilityIssue = "The selected independent judge is unavailable or its external-evidence approval is missing."
        }

        let binding = ScenarioAssessmentSourceBinding(
            scenarioRunID: request.scenarioRunID,
            laneResultID: request.laneResult.id,
            caseID: request.laneResult.caseID,
            lane: request.laneResult.lane,
            attempt: request.laneResult.attempt,
            assertionID: request.assertion.id,
            observationKey: request.assertion.observationKey,
            rawOutputDigest: digest(response),
            verifiedReferenceDigest: digest(request.verifiedReference),
            rubricDigest: digest(rubric)
        )
        let sourceBindingDigest = try digest(CanonicalJSON.data(for: binding, prettyPrinted: false))
        let policy = ScenarioJudgePolicySnapshot(
            scoringContract: contract,
            promptVersion: EvaluationRunner.judgePromptVersion,
            passingScore: EvaluationSuite.judgePassingScore,
            judgeMode: request.judgeConfiguration.mode,
            connectionID: request.judgeConfiguration.connectionID,
            connectionDisclosureDigest: policyJudge?.connection.disclosureDigest
                ?? request.judgeConfiguration.approvedConnectionDigest,
            includeReferenceAttachments: request.judgeConfiguration.includeReferenceAttachments
        )
        let policyDigest = try digest(CanonicalJSON.data(for: policy, prettyPrinted: false))

        let sample = EvaluationSampleResult(
            id: request.laneResult.id,
            caseID: request.laneResult.caseID,
            caseName: evaluationCase.name,
            repetition: request.laneResult.attempt,
            prompt: request.effectiveInput,
            effectivePrompt: request.effectiveInput,
            expected: request.verifiedReference,
            response: response,
            status: .unscored,
            score: nil,
            rationale: nil,
            durationMilliseconds: 0,
            usage: EvaluationUsage(),
            judgeDurationMilliseconds: nil,
            judgeUsage: nil,
            errorCategory: request.laneResult.executionStatus == .completed ? nil : "incompleteScenarioExecution",
            errorMessage: request.laneResult.executionStatus == .completed ? nil : "The route did not complete.",
            judgeErrorCategory: nil,
            judgeErrorMessage: nil
        )
        let syntheticRun = EvaluationRun(
            id: request.scenarioRunID,
            suiteID: suite.id,
            suiteName: suite.name,
            suiteVersion: suite.version,
            instructions: suite.instructions,
            criteria: suite.criteria,
            scoringMode: suite.scoringMode,
            repetitions: 1,
            judgePromptVersion: EvaluationRunner.judgePromptVersion,
            judgePassingScore: EvaluationSuite.judgePassingScore,
            plannedSampleCount: 1,
            plannedCases: [evaluationCase],
            startedAt: request.laneResult.startedAt,
            completedAt: request.laneResult.completedAt,
            cancelled: request.laneResult.executionStatus == .cancelled,
            terminationReason: nil,
            environment: .init(operatingSystem: "Captured scenario route", locale: "", model: "Subject model unreported", modelContextSize: 0),
            attachments: [],
            results: [sample]
        )
        let assessment = try await service.reassess(
            run: syntheticRun,
            suite: suite,
            images: [],
            resolved: policyJudge,
            scoringContract: contract,
            subjectEvidenceDigest: sourceBindingDigest
        )
        let effectiveAvailabilityIssue = assessment.samples.allSatisfy {
            $0.status == .passed || $0.status == .failed
        } ? nil : (availabilityIssue ?? assessment.samples.first?.errorMessage
            ?? "The independent judge did not produce a complete assessment.")
        return .init(
            scenarioRunID: request.scenarioRunID,
            laneResultID: request.laneResult.id,
            caseID: request.laneResult.caseID,
            lane: request.laneResult.lane,
            attempt: request.laneResult.attempt,
            assertionID: request.assertion.id,
            observationKey: request.assertion.observationKey,
            verifiedReference: request.verifiedReference,
            rubric: rubric,
            effectiveInput: request.effectiveInput,
            rawOutputDigest: binding.rawOutputDigest,
            verifiedReferenceDigest: binding.verifiedReferenceDigest,
            rubricDigest: binding.rubricDigest,
            judgePolicyDigest: policyDigest,
            judgePolicy: policy,
            sourceBindingDigest: sourceBindingDigest,
            scoringContract: contract,
            assessment: assessment,
            availabilityIssue: effectiveAvailabilityIssue,
            assessmentStartedAt: assessmentStartedAt
        )
    }

    static func digest(_ string: String) -> String { digest(Data(string.utf8)) }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
