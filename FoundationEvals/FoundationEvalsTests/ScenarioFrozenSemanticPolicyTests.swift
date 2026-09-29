import Foundation
import Testing
@testable import FoundationEvals

struct ScenarioFrozenSemanticPolicyTests {
    private func definition() throws -> ScenarioDefinition {
        var value = ScenarioDefinition.starter()
        value.schemaVersion = ScenarioDefinition.stableSchemaVersion
        value.purpose = .releaseRequirement
        value.goal.requestText = "Summarize the packing note."
        value.assertions = [.init(
            kind: .semanticRubric, observationKey: "feature.response",
            expectedValue: .string("Pack the blue charger."),
            explanation: "Cover the requested note without adding unsupported facts.",
            applicableLanes: [.appFeature]
        )]
        return try value.frozen()
    }

    private func persistedBasicDefinition() throws -> ScenarioDefinition {
        var value = ScenarioDefinition.starter()
        value.target.destinationIdentifier = "physical-device-1"
        value.schemaVersion = ScenarioDefinition.stableSchemaVersion
        value.goal.requestText = ""
        value.goal.languageCode = ""
        value.goal.expectedBehavior = ""
        value.fixture = .init(
            id: "", version: "", digest: "", isSynthetic: false,
            preparationOperation: "", cleanupOperation: ""
        )
        value.assertions = [.init(
            kind: .returnedField, observationKey: "taskID",
            expectedValue: .string("task-001"), explanation: "The returned task ID matches.",
            applicableLanes: [.intentIntegration]
        )]
        value.directControl.outputFields = [.init(
            name: "taskID", type: .primitive(.string),
            path: [.init(kind: .property, name: "value")]
        )]
        value.coverage.appFeature = .notApplicable
        value.coverage.siri = .notApplicable
        value.purpose = .exploratory
        value.checkMode = .basic
        value.requiredClaims = [.executionCompleted, .returnedValueChecked]
        value.observationPlan = [.init(id: "taskID", source: .intentResult)]
        value.integration = .init(id: "tasks", version: "1.0", digest: String(repeating: "a", count: 64))
        return try value.frozen()
    }

    private func judge() -> EvaluationResolvedJudgeConnection {
        .init(connection: .init(
            id: UUID(), name: "Local judge", kind: .localCompatible,
            baseURL: "http://127.0.0.1:11434/v1", modelID: "configured-model"
        ), apiKey: nil)
    }

    private func configuration(for judge: EvaluationResolvedJudgeConnection) -> EvaluationJudgeConfiguration {
        var value = EvaluationJudgeConfiguration()
        value.mode = .connection
        value.connectionID = judge.connection.id
        value.includeReferenceAttachments = true
        value.externalEvidenceApprovedAt = Date()
        value.approvedConnectionID = judge.connection.id
        value.approvedConnectionDigest = judge.connection.disclosureDigest
        value.approvedIncludeReferenceAttachments = true
        return value
    }

    @Test func frozenPolicyBindsIndependentAssessmentAndRejectsOlderJudgments() async throws {
        let definition = try definition()
        let judge = judge()
        let configuration = configuration(for: judge)
        let policy = try ScenarioFrozenSemanticPolicy.make(
            definition: definition, assertionID: definition.assertions[0].id,
            configuration: configuration, resolvedJudge: judge
        )
        let now = Date()
        let lane = ScenarioLaneResult(
            caseID: definition.id, attempt: 1, lane: .appFeature,
            executionStatus: .completed, outcome: .needsReview,
            startedAt: now, completedAt: now,
            observations: ["feature.response": .string("Pack the blue charger.")]
        )
        // No endpoint is called. The unavailable judge stays unscored, while
        // the independently frozen contract must match the real assessment path.
        let assessment = try await ScenarioIndependentAssessmentService.assess(
            .init(scenarioRunID: UUID(), laneResult: lane,
                  assertion: definition.assertions[0],
                  effectiveInput: definition.goal.requestText,
                  verifiedReference: "Pack the blue charger.",
                  judgeConfiguration: configuration),
            resolvedJudge: nil
        )
        let projection = try assessment.portableProjection()
        let pins = try policy.requirementPolicy()
        #expect(assessment.sample?.status == .unscored)
        #expect(pins.scoringContractDigest == projection.scoringContractDigest)
        #expect(pins.judgePolicyDigest == projection.judgePolicyDigest)
        let artifact = try assessment.portableArtifact()
        #expect(artifact.hasTrustedBinding(
            definition: definition, laneResult: lane,
            expectedScoringContractDigest: pins.scoringContractDigest,
            expectedJudgePolicyDigest: pins.judgePolicyDigest,
            frozenPolicyAt: pins.frozenAt
        ))
        let assessedAt = try #require(assessment.assessmentStartedAt)
        #expect(!artifact.hasTrustedBinding(
            definition: definition, laneResult: lane,
            expectedScoringContractDigest: pins.scoringContractDigest,
            expectedJudgePolicyDigest: pins.judgePolicyDigest,
            frozenPolicyAt: assessedAt + 0.001
        ))
        var legacy = assessment
        legacy.assessmentStartedAt = nil
        let legacyArtifact = try legacy.portableArtifact()
        #expect(legacyArtifact.hasTrustedBinding(
            definition: definition, laneResult: lane,
            expectedScoringContractDigest: pins.scoringContractDigest,
            expectedJudgePolicyDigest: pins.judgePolicyDigest
        ))
        #expect(!legacyArtifact.hasTrustedBinding(
            definition: definition, laneResult: lane,
            expectedScoringContractDigest: pins.scoringContractDigest,
            expectedJudgePolicyDigest: pins.judgePolicyDigest,
            frozenPolicyAt: pins.frozenAt
        ))
    }

    @Test func policyRequiresApprovalForTheActualConnection() throws {
        let definition = try definition()
        let judge = judge()
        var configuration = configuration(for: judge)
        configuration.approvedConnectionDigest = nil
        #expect(throws: ScenarioAssessmentStoreError.self) {
            try ScenarioFrozenSemanticPolicy.make(
                definition: definition, assertionID: definition.assertions[0].id,
                configuration: configuration, resolvedJudge: judge
            )
        }
    }

    @Test func policyPersistsAndRejectsReplacementJudge() async throws {
        let definition = try definition()
        let firstJudge = judge()
        let first = try ScenarioFrozenSemanticPolicy.make(
            definition: definition, assertionID: definition.assertions[0].id,
            configuration: configuration(for: firstJudge), resolvedJudge: firstJudge
        )
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScenarioAssessmentStore(directory: root)
        #expect(try await store.frozenSemanticPolicy(definition: definition)?.definitionID == nil)
        try await store.freezeSemanticPolicy(first, definition: definition)
        var sameChoiceLater = first
        sameChoiceLater.frozenAt += 10
        try await store.freezeSemanticPolicy(sameChoiceLater, definition: definition)
        let reloaded = ScenarioAssessmentStore(directory: root)
        let saved = try #require(await reloaded.frozenSemanticPolicy(definition: definition))
        #expect(try saved.requirementPolicy() == first.requirementPolicy())
        let otherJudge = judge()
        let replacement = try ScenarioFrozenSemanticPolicy.make(
            definition: definition, assertionID: definition.assertions[0].id,
            configuration: configuration(for: otherJudge), resolvedJudge: otherJudge
        )
        await #expect(throws: ScenarioAssessmentStoreError.self) {
            try await reloaded.freezeSemanticPolicy(replacement, definition: definition)
        }
        let retained = try #require(await reloaded.frozenSemanticPolicy(definition: definition))
        #expect(try retained.requirementPolicy() == first.requirementPolicy())
    }

    @Test func changedFrozenRequirementCannotReusePolicy() async throws {
        let definition = try definition()
        let judge = judge()
        let policy = try ScenarioFrozenSemanticPolicy.make(
            definition: definition, assertionID: definition.assertions[0].id,
            configuration: configuration(for: judge), resolvedJudge: judge
        )
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScenarioAssessmentStore(directory: root)
        try await store.freezeSemanticPolicy(policy, definition: definition)
        var changed = definition
        changed.assertions[0].expectedValue = .string("A different reference")
        changed = try changed.frozen()
        await #expect(throws: ScenarioAssessmentStoreError.self) {
            try await store.frozenSemanticPolicy(definition: changed)
        }
    }

    @Test func differentRequiredRubricsCannotShareOnePin() throws {
        var definition = try definition()
        definition.assertions.append(.init(
            kind: .semanticRubric, observationKey: "other.response",
            expectedValue: .string("Another reference"), explanation: "A different rubric.",
            applicableLanes: [.appFeature]
        ))
        definition = try definition.frozen()
        let judge = judge()
        #expect(throws: ScenarioAssessmentStoreError.self) {
            try ScenarioFrozenSemanticPolicy.make(
                definition: definition, assertionID: definition.assertions[0].id,
                configuration: configuration(for: judge), resolvedJudge: judge
            )
        }
    }
    @Test func requiredPolicyDoesNotRestrictOptionalRubricsOrJudges() throws {
        var definition = try definition()
        let optional = ScenarioAssertion(
            kind: .semanticRubric, observationKey: "optional.response",
            expectedValue: .string("Different reference"), explanation: "Different optional rubric.",
            required: false, applicableLanes: [.appFeature]
        )
        definition.assertions.append(optional)
        definition = try definition.frozen()
        let requiredJudge = judge()
        let otherJudge = judge()
        let policy = try ScenarioFrozenSemanticPolicy.make(
            definition: definition, assertionID: definition.assertions[0].id,
            configuration: configuration(for: requiredJudge), resolvedJudge: requiredJudge
        )
        try policy.validateAssessmentJudge(
            definition: definition, assertionID: optional.id,
            configuration: configuration(for: otherJudge), resolvedJudge: otherJudge
        )
        #expect(throws: ScenarioAssessmentStoreError.self) {
            try policy.validateAssessmentJudge(
                definition: definition, assertionID: definition.assertions[0].id,
                configuration: configuration(for: otherJudge), resolvedJudge: otherJudge
            )
        }
    }

    @MainActor
    @Test func oldAssessmentCompletionPreservesCurrentSelectionOverlay() async throws {
        let support = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let root = support.appending(path: "IntentLab")
        let definition = try persistedBasicDefinition()
        let profile = ScenarioExecutionProfile(
            id: UUID(), projectPath: "/example/App.xcodeproj", scheme: "App",
            testTarget: "AppTests", destinationIdentifier: "device",
            signingSelection: nil, trustedConnectionID: nil, buildConfiguration: "Debug"
        )
        let plan = try ScenarioExecutionPlan.make(
            definition: definition, profile: profile, appProductDigest: "app",
            testProductDigest: "tests", sourceInputsDigest: "source",
            runnerBuildID: "app", runnerID: UUID()
        )
        let record = try ScenarioExecutionRecord.make(
            plan: plan, records: plan.coordinates.map(ScenarioExecutionCoordinateRecord.unstarted)
        )
        let persistence = ScenarioPersistence(rootDirectory: root)
        try await persistence.saveDefinition(definition)
        try await persistence.savePlan(plan)
        try await persistence.saveExecutionRecord(record)
        _ = try await ScenarioAssessmentStore(directory: root.appending(path: "Assessments"))
            .sealSelection(executionRecord: record, runs: [], definition: definition)
        let coordinator = ScenarioCoordinator(
            supportDirectory: support, evaluationStore: EvaluationStore(supportDirectory: support),
            executionAdmission: ScenarioExecutionAdmission()
        )
        await coordinator.load()
        coordinator.selectedExecutionID = record.id
        await coordinator.reloadSelectedAssessmentOverlay(expectedExecutionID: record.id)
        let overlay = try #require(coordinator.selectedAssessmentOverlay)
        let history = coordinator.assessmentSelectionHistory
        #expect(!history.isEmpty)
        await coordinator.reloadSelectedAssessmentOverlay(expectedExecutionID: UUID())
        #expect(coordinator.selectedAssessmentOverlay?.id == overlay.id)
        #expect(coordinator.assessmentSelectionHistory.map(\.id) == history.map(\.id))
    }

}
