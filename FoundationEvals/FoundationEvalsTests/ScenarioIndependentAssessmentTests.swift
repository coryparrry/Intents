import Foundation
import Testing
@testable import FoundationEvals

struct ScenarioIndependentAssessmentTests {
    private func lane(
        id: UUID = UUID(),
        caseID: UUID = UUID(),
        response: String = "The note says to pack the blue charger."
    ) -> ScenarioLaneResult {
        let now = Date()
        return .init(
            id: id, caseID: caseID, attempt: 2, lane: .intentIntegration,
            executionStatus: .completed, outcome: .needsReview,
            startedAt: now, completedAt: now,
            observations: ["generatedSummary": .string(response)]
        )
    }

    private func request(
        laneResult: ScenarioLaneResult,
        reference: String = "The blue charger is on the packing list.",
        configuration: EvaluationJudgeConfiguration = .init()
    ) -> ScenarioAssessmentRequest {
        .init(
            scenarioRunID: UUID(), laneResult: laneResult,
            assertion: .init(
                kind: .semanticRubric,
                observationKey: "generatedSummary",
                expectedValue: .string(reference),
                explanation: "The summary covers the requested note without adding unsupported facts.",
                applicableLanes: [.intentIntegration]
            ),
            effectiveInput: "Summarize the packing note.",
            verifiedReference: reference,
            judgeConfiguration: configuration
        )
    }

    @Test func unavailableJudgeRetainsRawOutputAsUnscored() async throws {
        let raw = "The note says to pack the blue charger."
        let captured = lane(response: raw)
        let result = try await ScenarioIndependentAssessmentService.assess(
            request(laneResult: captured), resolvedJudge: nil
        )
        #expect(result.sample?.status == .unscored)
        #expect(result.availabilityIssue != nil)
        #expect(result.assessment.subjectEvidenceDigest == result.sourceBindingDigest)
        #expect(result.assessment.samples.first?.sampleID == captured.id)
        #expect(captured.observations["generatedSummary"] == .string(raw))
        #expect(result.rawOutputDigest.count == 64)
        #expect(result.assessment.judge.reportedModelID == "none")
    }

    @Test func missingApprovalCannotUseResolvedExternalJudge() async throws {
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Local judge", kind: .localCompatible,
            baseURL: "http://127.0.0.1:11434", modelID: "configured-model"
        )
        var configuration = EvaluationJudgeConfiguration()
        configuration.mode = .connection
        configuration.connectionID = connection.id
        let result = try await ScenarioIndependentAssessmentService.assess(
            request(laneResult: lane(), configuration: configuration),
            resolvedJudge: .init(connection: connection, apiKey: nil)
        )
        #expect(result.sample?.status == .unscored)
        #expect(result.availabilityIssue?.contains("approval") == true)
        #expect(result.assessment.judge.reportedModelID == "none")
    }

    @Test func savedExactCriterionUsesExistingObjectiveJudgePath() async throws {
        let captured = lane(response: "The blue charger is on the packing list.")
        var check = request(laneResult: captured, reference: "")
        check.assertion.expectedValue = nil
        check.assertion.explanation = "exact: \"The blue charger is on the packing list.\""
        let result = try await ScenarioIndependentAssessmentService.assess(check, resolvedJudge: nil)
        #expect(result.sample?.status == .passed)
        #expect(result.sample?.trace?.judgedCriterionIndexes == [])
        #expect(result.assessment.judge.requestedModelID == "none")
        #expect(captured.observations["generatedSummary"] == .string("The blue charger is on the packing list."))
    }

    @Test func retainedArtifactRecomputesScoredPassAndFailure() async throws {
        var definition = ScenarioDefinition.starter()
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.coverage.appFeature = .notApplicable
        definition.coverage.siri = .notApplicable
        definition.goal.requestText = "Summarize the packing note."
        let assertion = ScenarioAssertion(
            kind: .semanticRubric, observationKey: "generatedSummary",
            explanation: "exact: \"The blue charger is on the packing list.\"",
            applicableLanes: [.intentIntegration]
        )
        definition.assertions = [assertion]
        definition = try definition.frozen()

        for (response, expected) in [
            ("The blue charger is on the packing list.", ScenarioSelectedAssessmentStatus.passed),
            ("The note says to pack a red charger.", ScenarioSelectedAssessmentStatus.failed),
        ] {
            let captured = lane(caseID: definition.id, response: response)
            let request = ScenarioAssessmentRequest(
                scenarioRunID: UUID(), laneResult: captured, assertion: assertion,
                effectiveInput: definition.goal.requestText,
                verifiedReference: "", judgeConfiguration: .init()
            )
            let assessed = try await ScenarioIndependentAssessmentService.assess(
                request, resolvedJudge: nil
            )
            let projection = try assessed.portableProjection()
            let artifact = try assessed.portableArtifact()
            #expect(projection.status == expected)
            #expect(artifact.hasTrustedBinding(
                definition: definition, laneResult: captured,
                expectedScoringContractDigest: projection.scoringContractDigest,
                expectedJudgePolicyDigest: projection.judgePolicyDigest
            ))

            var json = try #require(JSONSerialization.jsonObject(with: artifact.retainedAssessmentJSON)
                as? [String: Any])
            var assessment = try #require(json["assessment"] as? [String: Any])
            var samples = try #require(assessment["samples"] as? [[String: Any]])
            samples[0]["status"] = expected == .passed ? "failed" : "passed"
            assessment["samples"] = samples
            json["assessment"] = assessment
            var forgedProjection = projection
            forgedProjection.status = expected == .passed ? .failed : .passed
            let forged = try ScenarioRetainedAssessmentArtifact.make(
                projection: forgedProjection,
                retainedAssessmentJSON: JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            )
            #expect(!forged.hasTrustedBinding(
                definition: definition, laneResult: captured,
                expectedScoringContractDigest: projection.scoringContractDigest,
                expectedJudgePolicyDigest: projection.judgePolicyDigest
            ))
        }
    }

    @Test func reassessmentKeepsEarlierAssessmentAndRouteSelection() async throws {
        let firstLane = lane()
        var firstRequest = request(laneResult: firstLane)
        firstRequest.scenarioRunID = UUID()
        let first = try await ScenarioIndependentAssessmentService.assess(firstRequest, resolvedJudge: nil)
        let second = try await ScenarioIndependentAssessmentService.assess(firstRequest, resolvedJudge: nil)
        #expect(first.id != second.id)
        #expect(first.rawOutputDigest == second.rawOutputDigest)
        #expect(first.verifiedReferenceDigest == second.verifiedReferenceDigest)
        #expect(first.scoringContract == second.scoringContract)

        var history = ScenarioAssessmentHistory()
        try history.append(first)
        try history.append(second)
        #expect(history.assessments.count == 2)
        #expect(history.selected(for: firstLane.id, assertionID: firstRequest.assertion.id)?.id == second.id)
        try history.select(first.id, for: firstLane.id, assertionID: firstRequest.assertion.id)
        #expect(history.selected(for: firstLane.id, assertionID: firstRequest.assertion.id)?.id == first.id)
        #expect(history.assessments.count == 2)
    }

    @Test func changedReferenceCannotBeAssessedUnderOldRequirement() async throws {
        let captured = lane()
        var changed = request(laneResult: captured)
        changed.verifiedReference = "A different reference."
        await #expect(throws: ScenarioAssessmentError.self) {
            _ = try await ScenarioIndependentAssessmentService.assess(changed, resolvedJudge: nil)
        }
    }

    @Test func assessmentStoreRetainsSourceAcrossReloadAndRejectsChangedOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "scenario-assessments-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var definition = ScenarioDefinition.starter()
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.coverage.appFeature = .notApplicable
        definition.coverage.siri = .notApplicable
        definition.goal.requestText = "Summarize the packing note."
        let assertion = ScenarioAssertion(
            kind: .semanticRubric,
            observationKey: "generatedSummary",
            expectedValue: .string("The blue charger is on the packing list."),
            explanation: "The summary covers the requested note without adding unsupported facts.",
            applicableLanes: [.intentIntegration]
        )
        definition.assertions = [assertion]
        definition = try definition.frozen()
        let captured = lane(caseID: definition.id)
        let now = Date()
        let invocation = ScenarioInvocationIdentity(
            id: UUID(), nonce: UUID().uuidString, issuedAt: now,
            testIdentity: .init(bundleIdentifier: "example.tests", className: "ScenarioTests", methodName: "testScenario"),
            harnessVersion: ScenarioInvocationIdentity.reusableHarnessVersion,
            destinationIdentifier: "test-device", scenarioDigest: definition.definitionDigest,
            resultBundleIdentity: UUID().uuidString,
            appProduct: nil, testProduct: nil
        )
        let environment = ScenarioEnvironment(
            xcodeVersion: "27", sdkVersion: "27", deviceModel: "iPhone",
            operatingSystem: "iOS 27", operatingSystemBuild: nil,
            languageCode: "en", regionCode: "GB", timeZoneIdentifier: "Europe/London",
            siriConfiguration: nil, siriConfigurationSource: nil, executedAt: now
        )
        let run = ScenarioRun(
            id: invocation.id, scenarioID: definition.id, scenarioVersion: definition.version,
            scenarioDigest: definition.definitionDigest, invocation: invocation,
            startedAt: now, completedAt: now, environment: environment,
            executionStatus: .completed, outcome: .needsReview,
            laneResults: [captured], linkedFeatureRunID: nil, importedAt: now
        )
        let assessmentRequest = ScenarioAssessmentRequest(
            scenarioRunID: run.id, laneResult: captured, assertion: assertion,
            effectiveInput: definition.goal.requestText,
            verifiedReference: "The blue charger is on the packing list.",
            judgeConfiguration: .init()
        )
        let first = try await ScenarioIndependentAssessmentService.assess(assessmentRequest, resolvedJudge: nil)
        let second = try await ScenarioIndependentAssessmentService.assess(assessmentRequest, resolvedJudge: nil)
        let store = ScenarioAssessmentStore(directory: directory)
        var forged = first
        forged.assessment.id = UUID()
        forged.assessment.samples[0].status = .passed
        forged.availabilityIssue = nil
        await #expect(throws: ScenarioAssessmentStoreError.self) {
            try await store.append(forged, for: run, definition: definition)
        }
        try await store.append(first, for: run, definition: definition)
        try await store.append(first, for: run, definition: definition) // Retry save is idempotent.
        try await store.append(second, for: run, definition: definition)
        let reloaded = ScenarioAssessmentStore(directory: directory)
        let history = try await reloaded.history(for: run, laneResultID: captured.id, definition: definition)
        #expect(history.assessments.count == 2)
        #expect(history.selected(for: captured.id, assertionID: assertion.id)?.id == second.id)
        #expect(run.laneResults[0].observations["generatedSummary"] == captured.observations["generatedSummary"])

        var altered = run
        altered.laneResults[0].observations["generatedSummary"] = .string("A different generated summary")
        await #expect(throws: ScenarioAssessmentStoreError.self) {
            _ = try await reloaded.history(for: altered, laneResultID: captured.id, definition: definition)
        }
    }

    @Test func featureChildCanBeReassessedAndSelectedWithoutScenarioRun() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "feature-assessments-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var definition = ScenarioDefinition.starter()
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.coverage.siri = .notApplicable
        definition.goal.requestText = "Summarize the packing note."
        let assertion = ScenarioAssertion(
            kind: .semanticRubric, observationKey: "feature.response",
            expectedValue: .string("The note says to pack the blue charger."),
            explanation: "The summary covers the requested note without unsupported facts.",
            applicableLanes: [.appFeature]
        )
        definition.assertions.append(assertion)
        definition = try definition.frozen()
        let now = Date()
        let raw = "The note says to pack the blue charger."
        let lane = ScenarioLaneResult(
            caseID: definition.id, attempt: 1, lane: .appFeature,
            executionStatus: .completed, outcome: .needsReview,
            startedAt: now, completedAt: now,
            observations: ["feature.response": .string(raw)]
        )
        let child = try ScenarioFeatureChildEvidence(
            runID: UUID(), sampleID: UUID(), startedAt: now, completedAt: now,
            caseID: definition.id, attempt: 1, response: raw,
            encodedOutput: nil, encodedOutputTypeName: nil, outputMetadata: [:],
            errorCategory: nil, errorMessage: nil,
            appBundleIdentifier: definition.target.bundleIdentifier,
            featureID: "summarize-note", featureVersion: "1",
            checkedAppProductDigest: "checked-build", runnerBuildID: "checked-build",
            fixtureContractDigest: definition.fixture.digest,
            subjectInputDigest: nil, digest: ""
        ).sealed()
        let coordinate = ScenarioPlannedCoordinate(
            id: UUID(), caseID: definition.id, lane: .appFeature,
            repetition: 1, required: false
        )
        let coordinateRecord = ScenarioExecutionCoordinateRecord(
            coordinate: coordinate, state: .completed,
            evidenceRunID: child.runID, evidenceLaneResultID: lane.id,
            detail: nil, laneResult: lane, evidenceDigest: nil, featureChild: child
        )
        let executionRecord = ScenarioExecutionRecord(
            id: UUID(), planID: UUID(), records: [coordinateRecord],
            completedAt: now, evidenceDigest: String(repeating: "a", count: 64)
        )
        let store = ScenarioAssessmentStore(directory: directory)
        let first = try await store.reassessSavedFeatureOutput(
            coordinateID: coordinate.id, assertionID: assertion.id,
            executionRecord: executionRecord, definition: definition,
            judgeConfiguration: .init(), resolvedJudge: nil
        )
        #expect(first.sample?.status == .unscored)
        let reloaded = ScenarioAssessmentStore(directory: directory)
        let history = try await reloaded.featureHistory(
            for: executionRecord, laneResultID: lane.id, definition: definition
        )
        #expect(history.selected(for: lane.id, assertionID: assertion.id)?.id == first.id)
        let selection = try await reloaded.sealSelection(
            executionRecord: executionRecord, runs: [], definition: definition
        )
        #expect(selection.isBound(to: executionRecord))
        #expect(selection.assessments.count == 1)
        #expect(selection.assessments[0].hasTrustedRequirementBinding(
            definition: definition, laneResult: lane
        ))
        let artifacts = try await reloaded.retainedArtifacts(
            for: selection, executionRecord: executionRecord, runs: [], definition: definition
        )
        #expect(artifacts.count == 1)
        let artifact = try #require(artifacts.first)
        #expect(artifact.hasTrustedBinding(
            definition: definition, laneResult: lane,
            expectedScoringContractDigest: selection.assessments[0].scoringContractDigest,
            expectedJudgePolicyDigest: selection.assessments[0].judgePolicyDigest
        ))
        #expect(!artifact.hasTrustedBinding(
            definition: definition, laneResult: lane,
            expectedScoringContractDigest: String(repeating: "0", count: 64),
            expectedJudgePolicyDigest: selection.assessments[0].judgePolicyDigest
        ))
        let restored = try await reloaded.loadSelectionRecord(id: selection.id, executionRecord: executionRecord)
        #expect(restored.digest == selection.digest)

        var changed = executionRecord
        changed.records[0].featureChild?.response = "Changed after capture"
        await #expect(throws: ScenarioAssessmentStoreError.self) {
            _ = try await reloaded.featureHistory(
                for: changed, laneResultID: lane.id, definition: definition
            )
        }
    }

    @MainActor
    @Test func storeResolverRequiresFrozenChoiceAndCurrentDisclosureApproval() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "scenario-judge-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Local judge", kind: .localCompatible,
            baseURL: "http://127.0.0.1:11434", modelID: "configured-model"
        )
        try store.saveJudgeConnection(connection, apiKey: nil)
        var configuration = EvaluationJudgeConfiguration()
        configuration.mode = .connection
        configuration.connectionID = connection.id
        #expect(throws: EvaluationCompatibleJudgeError.self) {
            _ = try store.resolvedScenarioJudge(connectionID: connection.id, configuration: configuration)
        }
        configuration.externalEvidenceApprovedAt = Date()
        configuration.approvedConnectionID = connection.id
        configuration.approvedIncludeReferenceAttachments = configuration.includeReferenceAttachments
        configuration.approvedConnectionDigest = connection.disclosureDigest
        let resolved = try store.resolvedScenarioJudge(connectionID: connection.id, configuration: configuration)
        #expect(resolved.connection.id == connection.id)
        configuration.connectionID = UUID()
        #expect(throws: EvaluationStoreError.self) {
            _ = try store.resolvedScenarioJudge(connectionID: connection.id, configuration: configuration)
        }
    }
}
