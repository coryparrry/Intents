import CryptoKit
import CoreFoundation
import Foundation

struct ScenarioPlannedCoordinate: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var caseID: UUID
    var lane: ScenarioLane
    var repetition: Int
    var required: Bool
}

enum ScenarioExecutionPlanPurpose: String, Codable, Sendable {
    case fullRequirement
    case partialDiagnostic
}

/// Saved before dispatch. It freezes the exact population and checked product
/// the coordinator intended to run; later UI edits affect a different plan.
struct ScenarioExecutionPlan: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var definitionID: UUID
    var definitionVersion: Int
    var definitionDigest: String
    var testContractDigest: String
    var profile: ScenarioExecutionProfile
    var purpose: ScenarioExecutionPlanPurpose = .fullRequirement
    var appProductDigest: String
    var testProductDigest: String
    var fixtureContractDigest: String
    var coordinates: [ScenarioPlannedCoordinate]
    var comparisonPolicy: ScenarioComparisonPolicy?
    var createdAt: Date
    /// Hash of the checked source inputs at connection verification.
    var sourceInputsDigest: String? = nil
    /// Externally pinnable source label frozen with the verified products.
    /// git:<revision> is used only for a clean checkout; otherwise the
    /// checked build-input digest is explicitly labelled as a fallback.
    var sourceRevision: String? = nil
    /// The app process reports this executable digest during its trusted handshake.
    var runnerBuildID: String? = nil
    var runnerID: UUID? = nil

    /// Coordinates that must be ready and completed for requirement coverage.
    /// Optional coordinates remain frozen evidence but do not block required work.
    var requiredCoordinates: [ScenarioPlannedCoordinate] {
        coordinates.filter(\.required)
    }

    private enum CodingKeys: String, CodingKey {
        case id, definitionID, definitionVersion, definitionDigest, testContractDigest
        case profile, purpose, appProductDigest, testProductDigest, fixtureContractDigest
        case coordinates, comparisonPolicy, createdAt, sourceInputsDigest, sourceRevision
        case runnerBuildID, runnerID
    }

    static func make(
        definition: ScenarioDefinition,
        profile: ScenarioExecutionProfile,
        appProductDigest: String,
        testProductDigest: String,
        sourceInputsDigest: String,
        sourceRevision: String? = nil,
        runnerBuildID: String?,
        runnerID: UUID?,
        plannedCoordinates: [ScenarioPlannedCoordinate]? = nil,
        purpose: ScenarioExecutionPlanPurpose = .fullRequirement,
        comparisonPolicy: ScenarioComparisonPolicy? = nil,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> Self {
        guard definition.schemaVersion == ScenarioDefinition.stableSchemaVersion,
              definition.hasValidDigest,
              let contract = definition.testContractDigest,
              !sourceInputsDigest.isEmpty else {
            throw ScenarioPersistenceError.invalidRun("v3 execution plan")
        }
        var coordinates = plannedCoordinates ?? []
        if plannedCoordinates == nil {
            for lane in ScenarioLane.allCases where definition.coverage[lane] != .notApplicable {
                let count = lane == .siri ? max(1, definition.coverage.siriAttemptCount ?? 3) : 1
                for attempt in 1...count {
                    coordinates.append(.init(
                        id: UUID(), caseID: definition.id, lane: lane,
                        repetition: attempt, required: definition.coverage[lane] == .required
                    ))
                }
            }
        }
        let expected = ScenarioLane.allCases.flatMap { lane -> [String] in
            guard definition.coverage[lane] != .notApplicable else { return [] }
            let count = lane == .siri ? max(1, definition.coverage.siriAttemptCount ?? 3) : 1
            return (1...count).map { "\(definition.id):\(lane.rawValue):\($0):\(definition.coverage[lane] == .required)" }
        }
        let actual = coordinates.map { "\($0.caseID):\($0.lane.rawValue):\($0.repetition):\($0.required)" }
        let hasUniqueIDs = Set(coordinates.map(\.id)).count == coordinates.count
        let hasUniqueCoordinates = Set(actual).count == actual.count
        let populationIsValid: Bool
        switch purpose {
        case .fullRequirement:
            populationIsValid = actual.sorted() == expected.sorted()
        case .partialDiagnostic:
            let expectedCoordinates = Set(expected)
            populationIsValid = plannedCoordinates != nil && !actual.isEmpty
                && actual.allSatisfy(expectedCoordinates.contains)
                && hasUniqueCoordinates
        }
        guard populationIsValid, hasUniqueIDs else {
            throw ScenarioPersistenceError.invalidRun("planned coordinates")
        }
        if profile.featureBackend == .projectLocalTestControl,
           (runnerBuildID != nil || runnerID != nil) {
            throw ScenarioPersistenceError.invalidRun("local Feature control cannot claim a connected runner")
        }
        if profile.featureBackend == .projectLocalTestControl,
           definition.coverage.appFeature != .notApplicable,
           (definition.featureBinding == nil
               || definition.actionRequirements?.contains(where: {
                   $0.lane == .appFeature && $0.kind == .productionService
               }) != true) {
            throw ScenarioPersistenceError.invalidRun("local Feature control has no frozen binding and service action")
        }
        return .init(
            id: id, definitionID: definition.id, definitionVersion: definition.version,
            definitionDigest: definition.definitionDigest, testContractDigest: contract,
            profile: profile, purpose: purpose, appProductDigest: appProductDigest,
            testProductDigest: testProductDigest,
            fixtureContractDigest: definition.fixture.digest, coordinates: coordinates,
            comparisonPolicy: comparisonPolicy, createdAt: createdAt,
            sourceInputsDigest: sourceInputsDigest, sourceRevision: sourceRevision,
            runnerBuildID: runnerBuildID,
            runnerID: runnerID
        )
    }
}

extension ScenarioExecutionPlan {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        definitionID = try values.decode(UUID.self, forKey: .definitionID)
        definitionVersion = try values.decode(Int.self, forKey: .definitionVersion)
        definitionDigest = try values.decode(String.self, forKey: .definitionDigest)
        testContractDigest = try values.decode(String.self, forKey: .testContractDigest)
        profile = try values.decode(ScenarioExecutionProfile.self, forKey: .profile)
        purpose = try values.decodeIfPresent(ScenarioExecutionPlanPurpose.self, forKey: .purpose)
            ?? .fullRequirement
        appProductDigest = try values.decode(String.self, forKey: .appProductDigest)
        testProductDigest = try values.decode(String.self, forKey: .testProductDigest)
        fixtureContractDigest = try values.decode(String.self, forKey: .fixtureContractDigest)
        coordinates = try values.decode([ScenarioPlannedCoordinate].self, forKey: .coordinates)
        comparisonPolicy = try values.decodeIfPresent(ScenarioComparisonPolicy.self, forKey: .comparisonPolicy)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        sourceInputsDigest = try values.decodeIfPresent(String.self, forKey: .sourceInputsDigest)
        sourceRevision = try values.decodeIfPresent(String.self, forKey: .sourceRevision)
        runnerBuildID = try values.decodeIfPresent(String.self, forKey: .runnerBuildID)
        runnerID = try values.decodeIfPresent(UUID.self, forKey: .runnerID)
    }
}

enum ScenarioCoordinateTerminalState: String, Codable, Sendable {
    case completed
    case failedToExecute
    case blocked
    case cancelled
    case recoveryRequired
    case notRun
}

struct ScenarioExecutionCoordinateRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { coordinate.id }
    var coordinate: ScenarioPlannedCoordinate
    var state: ScenarioCoordinateTerminalState
    var evidenceRunID: UUID?
    var evidenceLaneResultID: UUID?
    var detail: String?
    /// A single independently observed result for this exact coordinate.
    var laneResult: ScenarioLaneResult? = nil
    var evidenceDigest: String? = nil
    var featureChild: ScenarioFeatureChildEvidence? = nil
    /// Captured before dispatch; save-only recovery must not substitute current code.
    var featureMeasurementImplementation: ScenarioMeasurementImplementation? = nil

    static func unstarted(_ coordinate: ScenarioPlannedCoordinate) -> Self {
        .init(coordinate: coordinate, state: .notRun,
              evidenceRunID: nil, evidenceLaneResultID: nil, detail: nil)
    }
}

enum ScenarioSelectedAssessmentStatus: String, Codable, Sendable {
    case passed
    case failed
    case unscored
}

/// Portable selected judge result for one saved route/attempt and semantic
/// assertion. The full native assessment remains in the append-only store.
struct ScenarioSelectedAssessmentProjection: Codable, Equatable, Sendable {
    var scenarioRunID: UUID
    var laneResultID: UUID
    var caseID: UUID
    var lane: ScenarioLane
    var attempt: Int
    var assertionID: UUID
    var observationKey: String
    var selectedAssessmentID: UUID
    var status: ScenarioSelectedAssessmentStatus
    var rawOutputDigest: String
    var verifiedReferenceDigest: String
    var rubricDigest: String
    var sourceBindingDigest: String
    var scoringContractDigest: String
    var judgePolicyDigest: String
    var judgePromptVersion: String
    var requestedJudgeModelID: String
    var reportedJudgeModelID: String?
    var judgeConnectionID: UUID?

    /// Recompute the three requirement-derived digests and the source seal
    /// from externally trusted v3 requirements and the saved raw observation.
    /// Scoring and judge policy digests still require an external policy pin.
    func hasTrustedRequirementBinding(
        definition: ScenarioDefinition,
        laneResult: ScenarioLaneResult
    ) -> Bool {
        guard definition.schemaVersion == ScenarioDefinition.stableSchemaVersion,
              definition.hasValidDigest,
              laneResult.id == laneResultID,
              laneResult.caseID == caseID,
              laneResult.lane == lane,
              laneResult.attempt == attempt,
              let assertion = definition.assertions.first(where: { $0.id == assertionID }),
              assertion.kind == .semanticRubric,
              assertion.applies(to: lane),
              assertion.observationKey == observationKey,
              case .string(let output)? = laneResult.observations[observationKey] else {
            return false
        }
        let reference: String
        switch assertion.expectedValue {
        case .string(let value): reference = value
        case nil: reference = ""
        default: return false
        }
        let expectedRaw = Self.sha256(Data(output.utf8))
        let expectedReference = Self.sha256(Data(reference.utf8))
        let expectedRubric = Self.sha256(Data(
            assertion.explanation.trimmingCharacters(in: .whitespacesAndNewlines).utf8
        ))
        guard rawOutputDigest == expectedRaw,
              verifiedReferenceDigest == expectedReference,
              rubricDigest == expectedRubric else { return false }
        struct SourceSeal: Encodable {
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
        let seal = SourceSeal(
            scenarioRunID: scenarioRunID, laneResultID: laneResultID,
            caseID: caseID, lane: lane, attempt: attempt, assertionID: assertionID,
            observationKey: observationKey, rawOutputDigest: rawOutputDigest,
            verifiedReferenceDigest: verifiedReferenceDigest, rubricDigest: rubricDigest
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(seal) else { return false }
        return sourceBindingDigest == Self.sha256(data)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Complete retained native assessment bytes, sealed beside the selected
/// projection. The portable checker decodes the evidence it needs from those
/// bytes and recomputes the decision; it never trusts the projection's status.
struct ScenarioRetainedAssessmentArtifact: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { projection.selectedAssessmentID }
    var projection: ScenarioSelectedAssessmentProjection
    var retainedAssessmentJSON: Data
    var digest: String

    static func make(
        projection: ScenarioSelectedAssessmentProjection,
        retainedAssessmentJSON: Data
    ) throws -> Self {
        guard !retainedAssessmentJSON.isEmpty,
              retainedAssessmentJSON.count <= 10_000_000 else {
            throw ScenarioPersistenceError.invalidRun("retained assessment size")
        }
        var artifact = Self(
            projection: projection, retainedAssessmentJSON: retainedAssessmentJSON, digest: ""
        )
        artifact.digest = try artifact.calculatedDigest()
        return artifact
    }

    var hasValidDigest: Bool { (try? calculatedDigest()) == digest }

    /// Trusted policy pins come from the caller, not this exported artifact.
    /// A scored result is accepted only when the retained sample, criterion
    /// checks and observed judge identity support the selected status.
    func hasTrustedBinding(
        definition: ScenarioDefinition,
        laneResult: ScenarioLaneResult,
        expectedScoringContractDigest: String,
        expectedJudgePolicyDigest: String,
        frozenPolicyAt: TimeInterval? = nil
    ) -> Bool {
        guard hasValidDigest,
              projection.hasTrustedRequirementBinding(
                definition: definition, laneResult: laneResult
              ),
              projection.scoringContractDigest == expectedScoringContractDigest,
              projection.judgePolicyDigest == expectedJudgePolicyDigest,
              let saved = try? JSONDecoder().decode(RetainedRecord.self, from: retainedAssessmentJSON),
              saved.scenarioRunID == projection.scenarioRunID,
              saved.laneResultID == projection.laneResultID,
              saved.caseID == projection.caseID,
              saved.lane == projection.lane,
              saved.attempt == projection.attempt,
              saved.assertionID == projection.assertionID,
              saved.observationKey == projection.observationKey,
              saved.rawOutputDigest == projection.rawOutputDigest,
              saved.verifiedReferenceDigest == projection.verifiedReferenceDigest,
              saved.rubricDigest == projection.rubricDigest,
              saved.sourceBindingDigest == projection.sourceBindingDigest,
              saved.judgePolicyDigest == projection.judgePolicyDigest,
              saved.rubric == definition.assertions.first(where: { $0.id == projection.assertionID })?
                .explanation.trimmingCharacters(in: .whitespacesAndNewlines),
              saved.effectiveInput == definition.goal.requestText,
              saved.scoringContract == saved.judgePolicy.scoringContract,
              saved.assessment.scoringContract == saved.scoringContract,
              saved.assessment.id == projection.selectedAssessmentID,
              saved.assessment.runID == projection.scenarioRunID,
              saved.assessment.subjectEvidenceDigest == projection.sourceBindingDigest,
              saved.assessment.rubric == saved.rubric,
              saved.assessment.promptVersion == projection.judgePromptVersion,
              saved.assessment.passingScore == saved.judgePolicy.passingScore,
              saved.assessment.judge.requestedModelID == projection.requestedJudgeModelID,
              saved.assessment.judge.reportedModelID == projection.reportedJudgeModelID,
              saved.assessment.judge.connectionID == projection.judgeConnectionID,
              saved.assessment.samples.count == 1,
              saved.assessment.samples[0].sampleID == projection.laneResultID,
              saved.scoringContract.scoringMode == "modelJudge",
              saved.scoringContract.judgePromptVersion == projection.judgePromptVersion,
              saved.scoringContract.judgePassingScore == saved.assessment.passingScore,
              let scoringDigest = Self.digest(saved.scoringContract),
              scoringDigest == expectedScoringContractDigest,
              let policyDigest = Self.digest(saved.judgePolicy),
              policyDigest == expectedJudgePolicyDigest else { return false }

        if let frozenPolicyAt {
            guard frozenPolicyAt.isFinite, frozenPolicyAt > 0,
                  let assessedAt = saved.assessmentStartedAt, assessedAt.isFinite,
                  assessedAt >= frozenPolicyAt else { return false }
        }

        let criteria = saved.rubric.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard (1...4).contains(criteria.count),
              saved.scoringContract.rubricCriteria == criteria,
              case .string(let output)? = laneResult.observations[projection.observationKey],
              saved.verifiedReference == Self.reference(in: definition, assertionID: projection.assertionID)
        else { return false }

        let sample = saved.assessment.samples[0]
        switch sample.status {
        case "passed", "failed":
            let objective = criteria.enumerated().compactMap { index, criterion -> (Int, String)? in
                Self.expectedExactText(in: criterion).map { (index + 1, $0) }
            }
            let semanticIndexes = Set(1...criteria.count).subtracting(objective.map(\.0))
            guard saved.availabilityIssue == nil,
                  sample.errorCategory == nil, sample.errorMessage == nil,
                  let score = sample.score,
                  let trace = sample.trace,
                  trace.validationError == nil,
                  let checks = trace.checks,
                  checks.count == criteria.count,
                  Set(checks.map(\.criterionIndex)) == Set(1...criteria.count),
                  checks.allSatisfy({ check in
                      (1...4).contains(check.score)
                          && check.criterion == criteria[check.criterionIndex - 1]
                          && check.exactComparisons.allSatisfy {
                              $0.matches == (output == $0.expectedText)
                          }
                  }),
                  objective.allSatisfy({ pair in
                      let (index, expected) = pair
                      guard let check = checks.first(where: { $0.criterionIndex == index }) else { return false }
                      return check.exactComparisons.count == 1
                          && check.exactComparisons[0].expectedText == expected
                          && check.score == (output == expected ? 4 : 1)
                  }),
                  Set(trace.judgedCriterionIndexes ?? []) == semanticIndexes,
                  score == checks.map(\.score).min(),
                  sample.status == (score >= saved.assessment.passingScore ? "passed" : "failed"),
                  projection.status.rawValue == sample.status else { return false }
            if semanticIndexes.isEmpty {
                return saved.assessment.judge.requestedModelID == "none"
            }
            return saved.judgePolicy.judgeMode == "connection"
                && saved.judgePolicy.connectionID == projection.judgeConnectionID
                && saved.assessment.judge.mode == "connection"
                && saved.assessment.observedJudgeIdentities?.count == 1
                && saved.assessment.observedJudgeIdentities?.first?.connectionID == projection.judgeConnectionID
        case "unscored", "error":
            return projection.status == .unscored
        default:
            return false
        }
    }

    private func calculatedDigest() throws -> String {
        var copy = self
        copy.digest = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Self.sha256(try encoder.encode(copy))
    }

    private static func digest<Value: Encodable>(_ value: Value) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(value) else { return nil }
        return sha256(bytes)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func reference(in definition: ScenarioDefinition, assertionID: UUID) -> String? {
        guard let assertion = definition.assertions.first(where: { $0.id == assertionID }) else { return nil }
        switch assertion.expectedValue {
        case .string(let value): return value
        case nil: return ""
        default: return nil
        }
    }

    private static func expectedExactText(in criterion: String) -> String? {
        let line = criterion.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("exact:") {
            return decodeJSONString(String(line.dropFirst("exact:".count))
                .trimmingCharacters(in: .whitespaces))
        }
        for prefix in ["The final response is exactly ", "The response is exactly "]
        where line.hasPrefix(prefix) && line.hasSuffix(".") {
            let literal = String(line.dropFirst(prefix.count).dropLast())
            if let decoded = decodeJSONString(literal) { return decoded }
            let forbidden: Set<String> = ["AND", "OR", "IF", "UNLESS", "EXCEPT", "BUT", "THEN"]
            let words = literal.split(separator: " ")
            guard !literal.isEmpty, literal.count <= 256,
                  literal == literal.trimmingCharacters(in: .whitespaces),
                  (1...8).contains(words.count),
                  words.allSatisfy({ !forbidden.contains(String($0)) }),
                  literal.utf8.allSatisfy({ byte in
                      (65...90).contains(byte) || (48...57).contains(byte)
                          || byte == 32 || byte == 95 || byte == 45
                  }) else { return nil }
            return literal
        }
        return nil
    }

    private static func decodeJSONString(_ literal: String) -> String? {
        guard literal.first == "\"" else { return nil }
        return try? JSONDecoder().decode(String.self, from: Data(literal.utf8))
    }

    private struct RetainedRecord: Decodable {
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
        var sourceBindingDigest: String
        var judgePolicyDigest: String
        var scoringContract: ScoringContract
        var judgePolicy: JudgePolicy
        var assessment: Assessment
        var availabilityIssue: String?
        var assessmentStartedAt: TimeInterval?
    }

    private struct ScoringContract: Codable, Equatable {
        var scoringMode: String
        var rubricCriteria: [String]
        var judgePromptVersion: String?
        var judgePassingScore: Int?
        var casesDigest: String
    }

    private struct JudgePolicy: Codable {
        var scoringContract: ScoringContract
        var promptVersion: String
        var passingScore: Int
        var judgeMode: String
        var connectionID: UUID?
        var connectionDisclosureDigest: String?
        var includeReferenceAttachments: Bool
    }

    private struct Assessment: Decodable {
        var id: UUID
        var runID: UUID
        var judge: JudgeIdentity
        var promptVersion: String
        var rubric: String
        var passingScore: Int
        var samples: [Sample]
        var observedJudgeIdentities: [JudgeIdentity]?
        var scoringContract: ScoringContract?
        var subjectEvidenceDigest: String?
    }

    private struct JudgeIdentity: Decodable {
        var mode: String
        var connectionID: UUID?
        var requestedModelID: String
        var reportedModelID: String?
    }

    private struct Sample: Decodable {
        var sampleID: UUID
        var status: String
        var score: Int?
        var trace: Trace?
        var errorCategory: String?
        var errorMessage: String?
    }

    private struct Trace: Decodable {
        var checks: [CriterionCheck]?
        var validationError: String?
        var judgedCriterionIndexes: [Int]?
    }

    private struct CriterionCheck: Decodable {
        var criterionIndex: Int
        var criterion: String
        var score: Int
        var exactComparisons: [ExactComparison]
    }

    private struct ExactComparison: Decodable {
        var expectedText: String
        var matches: Bool
    }
}

/// The immutable terminal mapping from planned coordinates to child evidence.
struct ScenarioExecutionRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var planID: UUID
    var records: [ScenarioExecutionCoordinateRecord]
    var completedAt: Date
    var evidenceDigest: String
    /// Capture-time selection, if assessment completed before terminal seal.
    /// Later selections use a separate ScenarioAssessmentSelectionRecord.
    var selectedAssessments: [ScenarioSelectedAssessmentProjection]? = nil

    var isComplete: Bool { records.allSatisfy { $0.state == .completed } }
    var plannedCount: Int { records.count }
    var executedCount: Int { records.count { $0.state == .completed } }
    var observedCount: Int { records.count { $0.laneResult?.observations.isEmpty == false } }
    var scoredCount: Int { records.count { $0.laneResult?.assertionResults.isEmpty == false } }
    var passingCount: Int {
        records.count { $0.state == .completed && $0.laneResult?.outcome == .passed }
    }
    var aggregateOutcome: ScenarioOutcome {
        let required = records.filter { $0.coordinate.required }
        guard !required.isEmpty else { return .needsReview }
        if required.contains(where: { $0.state == .completed && $0.laneResult?.outcome == .failed }) {
            return .failed
        }
        guard required.allSatisfy({ $0.state == .completed && $0.laneResult?.executionStatus == .completed }) else {
            return .notObserved
        }
        guard required.allSatisfy({ $0.laneResult?.outcome == .passed }) else {
            return .needsReview
        }
        // Basic execution with no assertion is evidence capture, not a pass.
        guard required.allSatisfy({ $0.laneResult?.assertionResults.isEmpty == false }) else {
            return .needsReview
        }
        return .passed
    }

    static func make(
        plan: ScenarioExecutionPlan,
        records: [ScenarioExecutionCoordinateRecord],
        selectedAssessments: [ScenarioSelectedAssessmentProjection] = [],
        completedAt: Date = Date()
    ) throws -> Self {
        let laneIDs = records.compactMap(\.evidenceLaneResultID)
        let featureSampleIDs = records.compactMap { $0.featureChild?.sampleID }
        guard records.count == plan.coordinates.count,
              Set(records.map(\.id)) == Set(plan.coordinates.map(\.id)),
              Set(laneIDs).count == laneIDs.count,
              Set(featureSampleIDs).count == featureSampleIDs.count,
              records.allSatisfy({ item in
                  plan.coordinates.contains(item.coordinate)
                      && (item.laneResult == nil || (
                          item.laneResult?.caseID == item.coordinate.caseID
                          && item.laneResult?.lane == item.coordinate.lane
                          && item.laneResult?.attempt == item.coordinate.repetition
                          && item.laneResult?.id == item.evidenceLaneResultID
                      ))
                      && (item.featureChild == nil || (
                          item.coordinate.lane == .appFeature
                          && plan.profile.featureBackend == .connectedRunner
                          && item.featureChild?.runID == item.evidenceRunID
                          && item.featureChild?.caseID == item.coordinate.caseID
                          && item.featureChild?.attempt == item.coordinate.repetition
                          && item.featureChild?.hasValidDigest == true
                      ))
                      && (item.coordinate.lane != .appFeature
                          || item.state != .completed
                          || (plan.profile.featureBackend == .connectedRunner
                              ? item.featureChild != nil : item.featureChild == nil))
              }),
              selectedAssessmentsAreBound(selectedAssessments, to: records) else {
            throw ScenarioPersistenceError.invalidRun("coordinate population or selected assessment")
        }
        let sorted = records.sorted { $0.id.uuidString < $1.id.uuidString }
        let selected = sortedAssessments(selectedAssessments)
        let digest = try sealDigest(planID: plan.id, records: sorted, selectedAssessments: selected)
        return .init(id: plan.id, planID: plan.id, records: sorted,
                     completedAt: completedAt, evidenceDigest: digest,
                     selectedAssessments: selected.isEmpty ? nil : selected)
    }

    /// Canonical terminal seal bytes; nil and empty assessment selections share
    /// the same seal. Creation and verification use this exact wire contract.
    static func canonicalSealBytes(
        planID: UUID,
        records: [ScenarioExecutionCoordinateRecord],
        selectedAssessments: [ScenarioSelectedAssessmentProjection]
    ) throws -> Data {
        struct Seal: Encodable {
            var planID: UUID
            var records: [ScenarioExecutionCoordinateRecord]
            var selectedAssessments: [ScenarioSelectedAssessmentProjection]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Seal(
            planID: planID,
            records: records.sorted { $0.id.uuidString < $1.id.uuidString },
            selectedAssessments: sortedAssessments(selectedAssessments)
        ))
    }

    static func sealDigest(
        planID: UUID,
        records: [ScenarioExecutionCoordinateRecord],
        selectedAssessments: [ScenarioSelectedAssessmentProjection]
    ) throws -> String {
        SHA256.hash(data: try canonicalSealBytes(
            planID: planID, records: records, selectedAssessments: selectedAssessments
        )).map { String(format: "%02x", $0) }.joined()
    }

    static func sortedAssessments(
        _ assessments: [ScenarioSelectedAssessmentProjection]
    ) -> [ScenarioSelectedAssessmentProjection] {
        assessments.sorted {
            let left = "\($0.laneResultID.uuidString):\($0.assertionID.uuidString)"
            let right = "\($1.laneResultID.uuidString):\($1.assertionID.uuidString)"
            return left < right
        }
    }

    static func selectedAssessmentsAreBound(
        _ assessments: [ScenarioSelectedAssessmentProjection],
        to records: [ScenarioExecutionCoordinateRecord]
    ) -> Bool {
        let keys = assessments.map { "\($0.laneResultID.uuidString):\($0.assertionID.uuidString)" }
        guard Set(keys).count == keys.count else { return false }
        return assessments.allSatisfy { assessment in
            guard let item = records.first(where: {
                $0.evidenceRunID == assessment.scenarioRunID
                    && $0.evidenceLaneResultID == assessment.laneResultID
                    && $0.coordinate.caseID == assessment.caseID
                    && $0.coordinate.lane == assessment.lane
                    && $0.coordinate.repetition == assessment.attempt
            }), let lane = item.laneResult,
                  case .string(let output)? = lane.observations[assessment.observationKey],
                  !assessment.judgePromptVersion.isEmpty,
                  !assessment.requestedJudgeModelID.isEmpty,
                  [assessment.rawOutputDigest, assessment.verifiedReferenceDigest,
                   assessment.rubricDigest, assessment.sourceBindingDigest,
                   assessment.scoringContractDigest, assessment.judgePolicyDigest]
                    .allSatisfy({ $0.count == 64 }) else { return false }
            let outputDigest = SHA256.hash(data: Data(output.utf8))
                .map { String(format: "%02x", $0) }.joined()
            return assessment.rawOutputDigest == outputDigest
        }
    }
}

/// Immutable measurement selection made after subject execution was sealed.
/// A new selection creates a new record and names its predecessor; the child
/// execution record and raw app response are never rewritten.
struct ScenarioAssessmentSelectionRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var executionRecordID: UUID
    var executionRecordDigest: String
    var previousSelectionID: UUID?
    var selectedAt: Date
    var assessments: [ScenarioSelectedAssessmentProjection]
    var digest: String

    var hasValidDigest: Bool { (try? calculatedDigest()) == digest }

    static func make(
        executionRecord: ScenarioExecutionRecord,
        assessments: [ScenarioSelectedAssessmentProjection],
        previousSelectionID: UUID? = nil,
        id: UUID = UUID(),
        selectedAt: Date = Date()
    ) throws -> Self {
        guard ScenarioExecutionRecord.selectedAssessmentsAreBound(assessments, to: executionRecord.records),
              !executionRecord.evidenceDigest.isEmpty else {
            throw ScenarioPersistenceError.invalidRun("selected assessment binding")
        }
        var record = Self(
            id: id, executionRecordID: executionRecord.id,
            executionRecordDigest: executionRecord.evidenceDigest,
            previousSelectionID: previousSelectionID, selectedAt: selectedAt,
            assessments: ScenarioExecutionRecord.sortedAssessments(assessments), digest: ""
        )
        record.digest = try record.calculatedDigest()
        return record
    }

    func isBound(to executionRecord: ScenarioExecutionRecord) -> Bool {
        hasValidDigest && executionRecordID == executionRecord.id
            && executionRecordDigest == executionRecord.evidenceDigest
            && ScenarioExecutionRecord.selectedAssessmentsAreBound(assessments, to: executionRecord.records)
    }

    private func calculatedDigest() throws -> String {
        var copy = self
        copy.digest = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return SHA256.hash(data: try encoder.encode(copy))
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// Portable projection of one raw feature sample. The native EvaluationRun
/// remains the authoritative child; this sealed projection lets offline checks
/// bind a bundle coordinate to its observed output without UI-only model code.
struct ScenarioFeatureChildEvidence: Codable, Equatable, Sendable {
    var runID: UUID
    var sampleID: UUID
    var startedAt: Date
    var completedAt: Date
    var caseID: UUID
    var attempt: Int
    var response: String
    var encodedOutput: Data?
    var encodedOutputTypeName: String?
    var outputMetadata: [String: String]
    var errorCategory: String?
    var errorMessage: String?
    var appBundleIdentifier: String
    var featureID: String
    var featureVersion: String
    var checkedAppProductDigest: String
    var runnerBuildID: String
    var fixtureContractDigest: String
    var subjectInputDigest: String?
    var digest: String
    var measurementImplementation: ScenarioMeasurementImplementation? = nil

    var hasValidDigest: Bool { (try? calculatedDigest()) == digest }
    var hasVerifiedBuildBinding: Bool {
        !checkedAppProductDigest.isEmpty && runnerBuildID == checkedAppProductDigest
    }

    func calculatedDigest() throws -> String {
        var copy = self
        copy.digest = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(copy)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func sealed() throws -> Self {
        var copy = self
        copy.digest = try calculatedDigest()
        return copy
    }
}

/// Mutable crash checkpoint. Every coordinate starts as notRun and is marked
/// recoveryRequired before its app action is dispatched.
struct ScenarioExecutionProgress: Codable, Equatable, Sendable {
    var planID: UUID
    var records: [ScenarioExecutionCoordinateRecord]
    var updatedAt: Date
}

enum ScenarioExecutionEnvironmentIdentity {
    /// The environment is taken from the imported device envelope. The
    /// execution profile contributes only its checked destination binding.
    static func derive(
        environment: ScenarioEnvironment,
        destinationIdentifier: String,
        lane: ScenarioLane
    ) throws -> ScenarioEnvironmentIdentity? {
        let facts = [environment.xcodeVersion, environment.sdkVersion,
                     environment.deviceModel, environment.operatingSystem,
                     environment.languageCode, environment.regionCode,
                     environment.timeZoneIdentifier, destinationIdentifier]
        guard facts.allSatisfy({ !$0.isEmpty && $0.lowercased() != "unknown" }),
              lane != .siri || environment.siriConfigurationSource != nil else { return nil }
        struct Facts: Encodable {
            var destinationIdentifier: String
            var xcodeVersion: String
            var sdkVersion: String
            var deviceModel: String
            var operatingSystem: String
            var operatingSystemBuild: String?
            var languageCode: String
            var regionCode: String
            var timeZoneIdentifier: String
            var siriConfiguration: String?
            var siriConfigurationSource: ScenarioObservationSource?
        }
        let payload = Facts(
            destinationIdentifier: destinationIdentifier,
            xcodeVersion: environment.xcodeVersion, sdkVersion: environment.sdkVersion,
            deviceModel: environment.deviceModel, operatingSystem: environment.operatingSystem,
            operatingSystemBuild: environment.operatingSystemBuild,
            languageCode: environment.languageCode, regionCode: environment.regionCode,
            timeZoneIdentifier: environment.timeZoneIdentifier,
            siriConfiguration: environment.siriConfiguration,
            siriConfigurationSource: environment.siriConfigurationSource
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(payload))
            .map { String(format: "%02x", $0) }.joined()
        return .init(profileID: "device:\(destinationIdentifier)", profileDigest: digest)
    }
}

enum ScenarioFixtureReceipt: Equatable, Sendable {
    case missing
    case matched
    case wrongSource

    init(observed: String?, expected: String) {
        guard let observed, !observed.isEmpty else { self = .missing; return }
        self = observed == expected ? .matched : .wrongSource
    }

    init(observations: [String: ScenarioValue], expected: String) {
        let sourceValues = ["intentlab.fixtureDigest", "summarySourceContentDigest"]
            .compactMap { observations[$0] }
        var sourceDigests: [String] = []
        for value in sourceValues {
            guard case .string(let digest) = value, !digest.isEmpty else {
                self = .missing
                return
            }
            sourceDigests.append(digest)
        }
        if let catalog = observations["intentlab.fixtureDigests"] {
            guard case .string(let json) = catalog, json.utf8.count <= 8_192,
                  let digests = try? JSONDecoder().decode([String].self, from: Data(json.utf8)),
                  digests.count <= 32,
                  digests.allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) else {
                self = .missing
                return
            }
            guard digests.contains(expected) else { self = .wrongSource; return }
            // The catalog proves preparation. A selected source, when present,
            // still has to be the source that the contract planned.
            self = sourceDigests.allSatisfy({ $0 == expected }) ? .matched : .wrongSource
            return
        }
        guard !sourceDigests.isEmpty else { self = .missing; return }
        self = sourceDigests.allSatisfy({ $0 == expected }) ? .matched : .wrongSource
    }

    func outcome(after assessed: ScenarioOutcome) -> ScenarioOutcome {
        switch self {
        case .missing: .notObserved
        case .matched: assessed
        case .wrongSource: .failed
        }
    }
}

struct ScenarioFeatureSuiteIdentity: Equatable, Sendable {
    var id: UUID
    var suiteName: String
    var caseName: String

    init(definition: ScenarioDefinition) {
        let bytes = SHA256.hash(data: Data("\(definition.id):\(definition.testContractDigest ?? "")".utf8))
        let hex = bytes.prefix(16).map { String(format: "%02x", $0) }.joined()
        let formatted = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        id = UUID(uuidString: formatted)!
        suiteName = "Intent Lab contract \(definition.id.uuidString)"
        caseName = definition.id.uuidString
    }
}

enum ScenarioObservedFeatureOutput {
    /// Reads only fields actually present in the runner's encoded value.
    /// Missing or mistyped fields remain absent so required assertions fail.
    static func project(_ encoded: Data?, fields: [ScenarioOutputField]) -> [String: ScenarioValue] {
        guard let encoded,
              let root = try? JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed]) else {
            return [:]
        }
        var output: [String: ScenarioValue] = [:]
        for field in fields {
            var raw: Any = root
            let path = field.path ?? [.init(kind: .property, name: field.name)]
            var found = true
            for step in path {
                switch step.kind {
                case .property:
                    guard let name = step.name,
                          let value = (raw as? [String: Any])?[name] else { found = false; break }
                    raw = value
                case .index:
                    guard let index = step.index,
                          let values = raw as? [Any], values.indices.contains(index) else {
                        found = false; break
                    }
                    raw = values[index]
                case .count:
                    if let values = raw as? [Any] { raw = values.count }
                    else if let values = raw as? [String: Any] { raw = values.count }
                    else { found = false }
                }
                if !found { break }
            }
            if found, let value = typed(raw, as: field.type) { output[field.name] = value }
        }
        return output
    }

    private static func typed(_ raw: Any, as type: ScenarioValueType) -> ScenarioValue? {
        switch type {
        case .primitive(.string):
            return (raw as? String).map(ScenarioValue.string)
        case .primitive(.boolean):
            guard let number = raw as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return .boolean(number.boolValue)
        case .primitive(.integer):
            guard let number = raw as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite,
                  number.doubleValue.rounded() == number.doubleValue else { return nil }
            return .integer(number.int64Value)
        case .primitive(.number):
            guard let number = raw as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite else { return nil }
            return .number(number.doubleValue)
        case .array(let element):
            guard let items = raw as? [Any] else { return nil }
            let values = items.compactMap { typed($0, as: element) }
            return values.count == items.count ? .array(values) : nil
        case .primitive(.date), .enumeration, .entity:
            return nil
        }
    }
}

/// Portable subject-input identity used by dispatch, saved manifests and the
/// offline checker. It encodes the same tagged scalar/array values and fixture
/// reference fields as DeveloperSubjectInput, omitting execution correlation.
enum ScenarioFeatureSubjectDigest {
    struct FixtureReference: Codable, Equatable, Sendable {
        var identifier: String
        var contractDigest: String
    }

    struct Payload: Codable, Equatable, Sendable {
        var businessInputs: [String: ScenarioValue]
        var fixtureReferences: [FixtureReference]
    }

    enum InputError: Error, LocalizedError, Equatable {
        case duplicateField(String)
        case unsupportedValue(String)

        var errorDescription: String? {
            switch self {
            case .duplicateField(let name):
                "The feature binding maps \(name) more than once."
            case .unsupportedValue(let name):
                "The feature input \(name) cannot be encoded for the declared subject-input schema."
            }
        }
    }

    static func payload(binding: ScenarioFeatureBinding, fixture: ScenarioFixture) throws -> Payload {
        var inputs: [String: ScenarioValue] = [:]
        for mapping in binding.inputMapping {
            guard inputs[mapping.featureInputName] == nil else {
                throw InputError.duplicateField(mapping.featureInputName)
            }
            try validate(mapping.value, name: mapping.featureInputName)
            inputs[mapping.featureInputName] = mapping.value
        }
        let references: [FixtureReference] = fixture.id.isEmpty ? [] : [
            .init(identifier: fixture.id, contractDigest: fixture.digest)
        ]
        return .init(businessInputs: inputs, fixtureReferences: references)
    }

    static func digest(binding: ScenarioFeatureBinding, fixture: ScenarioFixture) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(payload(binding: binding, fixture: fixture))
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func validate(_ value: ScenarioValue, name: String) throws {
        switch value {
        case .null, .string, .boolean, .integer:
            return
        case .number(let number):
            guard number.isFinite else { throw InputError.unsupportedValue(name) }
        case .array(let values):
            for value in values { try validate(value, name: name) }
        case .date, .enumeration, .entity:
            throw InputError.unsupportedValue(name)
        }
    }
}

/// Digests normalized native evidence, not persisted file bytes. Acceptance is
/// host-owned state and does not change the captured run's evidence identity.
enum ScenarioNativeRunEvidence {
    static func canonicalBytes(_ run: ScenarioRun) throws -> Data {
        var immutableRun = run
        immutableRun.acceptanceStatus = .pending
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(immutableRun)
    }

    static func digest(_ run: ScenarioRun) throws -> String {
        SHA256.hash(data: try canonicalBytes(run))
            .map { String(format: "%02x", $0) }.joined()
    }
}
