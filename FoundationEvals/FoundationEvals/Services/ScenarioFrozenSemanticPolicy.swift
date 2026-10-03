import Foundation

/// A reviewed choice made before the independent judge reads saved output.
/// Kept beside assessment history, without changing the frozen app requirement.
struct ScenarioFrozenSemanticPolicy: Codable, Sendable {
    var definitionID: UUID
    var definitionVersion: Int
    var definitionDigest: String
    var testContractDigest: String
    var judgePolicy: ScenarioJudgePolicySnapshot
    var frozenAt: TimeInterval = Date().timeIntervalSince1970

    static func make(
        definition: ScenarioDefinition, assertionID: UUID,
        configuration: EvaluationJudgeConfiguration,
        resolvedJudge: EvaluationResolvedJudgeConnection
    ) throws -> Self {
        guard definition.schemaVersion == ScenarioDefinition.stableSchemaVersion,
              definition.hasValidDigest,
              let testContractDigest = definition.testContractDigest,
              let assertion = definition.assertions.first(where: { $0.id == assertionID }),
              assertion.kind == .semanticRubric,
              configuration.mode == .connection,
              configuration.connectionID == resolvedJudge.connection.id,
              configuration.hasCurrentExternalEvidenceApproval(for: resolvedJudge.connection) else {
            throw ScenarioAssessmentStoreError.invalidBinding("approved independent judge policy")
        }
        let contract = try scoringContract(definition: definition, assertion: assertion)
        let result = Self(
            definitionID: definition.id, definitionVersion: definition.version,
            definitionDigest: definition.definitionDigest,
            testContractDigest: testContractDigest,
            judgePolicy: .init(
                scoringContract: contract,
                promptVersion: EvaluationRunner.judgePromptVersion,
                passingScore: EvaluationSuite.judgePassingScore,
                judgeMode: .connection, connectionID: resolvedJudge.connection.id,
                connectionDisclosureDigest: resolvedJudge.connection.disclosureDigest,
                includeReferenceAttachments: configuration.includeReferenceAttachments
            )
        )
        try result.validate(definition: definition)
        return result
    }

    func validateAssessmentJudge(
        definition: ScenarioDefinition, assertionID: UUID,
        configuration: EvaluationJudgeConfiguration,
        resolvedJudge: EvaluationResolvedJudgeConnection?
    ) throws {
        try validate(definition: definition)
        guard let assertion = definition.assertions.first(where: { $0.id == assertionID }) else {
            throw ScenarioAssessmentStoreError.invalidBinding("semantic assertion")
        }
        // Optional assessments do not supply the required qualification policy.
        guard assertion.required else { return }
        guard let resolvedJudge else {
            throw ScenarioAssessmentStoreError.invalidBinding("Choose the frozen independent judge connection.")
        }
        let requested = try Self.make(
            definition: definition, assertionID: assertionID,
            configuration: configuration, resolvedJudge: resolvedJudge
        )
        guard try hasSameJudgingPolicy(as: requested) else {
            throw ScenarioAssessmentStoreError.invalidBinding("The selected judge differs from the frozen policy.")
        }
    }

    func validate(definition: ScenarioDefinition) throws {
        guard definition.hasValidDigest,
              definitionID == definition.id, definitionVersion == definition.version,
              definitionDigest == definition.definitionDigest,
              testContractDigest == definition.testContractDigest,
              judgePolicy.judgeMode == .connection,
              judgePolicy.connectionID != nil,
              judgePolicy.connectionDisclosureDigest?.count == 64,
              frozenAt.isFinite, frozenAt > 0,
              judgePolicy.promptVersion == EvaluationRunner.judgePromptVersion,
              judgePolicy.passingScore == EvaluationSuite.judgePassingScore else {
            throw ScenarioAssessmentStoreError.invalidBinding("frozen semantic policy")
        }
        let assertions = definition.assertions.filter { $0.required && $0.kind == .semanticRubric }
        guard !assertions.isEmpty else {
            throw ScenarioAssessmentStoreError.invalidBinding("required semantic assertion")
        }
        for assertion in assertions {
            guard try Self.scoringContract(definition: definition, assertion: assertion)
                == judgePolicy.scoringContract else {
                throw ScenarioAssessmentStoreError.invalidBinding(
                    "required semantic checks need different scoring policies"
                )
            }
        }
    }

    func requirementPolicy() throws -> IntentEvidenceRequirements.SemanticPolicy {
        .init(
            scoringContractDigest: ScenarioIndependentAssessmentService.digest(
                try CanonicalJSON.data(for: judgePolicy.scoringContract, prettyPrinted: false)
            ),
            judgePolicyDigest: ScenarioIndependentAssessmentService.digest(
                try CanonicalJSON.data(for: judgePolicy, prettyPrinted: false)
            ),
            frozenAt: frozenAt
        )
    }

    func hasSameJudgingPolicy(as other: Self) throws -> Bool {
        let current = try requirementPolicy()
        let requested = try other.requirementPolicy()
        return current.scoringContractDigest == requested.scoringContractDigest
            && current.judgePolicyDigest == requested.judgePolicyDigest
    }

    private static func scoringContract(
        definition: ScenarioDefinition, assertion: ScenarioAssertion
    ) throws -> EvaluationScoringContract {
        let reference: String
        switch assertion.expectedValue {
        case .string(let text): reference = text
        case nil: reference = ""
        default: throw ScenarioAssessmentStoreError.invalidBinding("semantic text reference")
        }
        let criteria = assertion.explanation.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard (1...4).contains(criteria.count) else {
            throw ScenarioAssessmentStoreError.invalidBinding("semantic rubric")
        }
        return try .init(
            scoringMode: .modelJudge, rubricCriteria: criteria,
            judgePromptVersion: EvaluationRunner.judgePromptVersion,
            judgePassingScore: EvaluationSuite.judgePassingScore,
            cases: [.init(id: definition.id, name: "Semantic assessment",
                          prompt: definition.goal.requestText, expected: reference)]
        )
    }
}
