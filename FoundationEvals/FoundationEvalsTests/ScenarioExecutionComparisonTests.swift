import CryptoKit
import Foundation
import Testing
@testable import FoundationEvals

struct ScenarioExecutionComparisonTests {
    @Test func freshChildIDsAndChangedBuildRemainComparable() throws {
        let caseID = UUID()
        let baseline = try snapshot(caseID: caseID, build: hash("a"), featureOutcome: .failed)
        let candidate = try snapshot(caseID: caseID, build: hash("b"), featureOutcome: .passed,
                                     baselineID: baseline.plan.id)
        #expect(baseline.plan.coordinates.map(\.id) != candidate.plan.coordinates.map(\.id))
        #expect(baseline.record.records.compactMap(\.evidenceRunID)
            != candidate.record.records.compactMap(\.evidenceRunID))
        let report = ScenarioExecutionComparison.compare(
            baseline: baseline, candidate: candidate,
            policy: .init(mode: .compareAppChanges, baselineRunID: baseline.plan.id)
        )
        #expect(report.isDirectlyComparable)
        #expect(report.summary.contains("Observed improvement"))
        #expect(report.lanes.first { $0.lane == .appFeature }?.candidatePassed == 1)
        #expect(report.lanes.first { $0.lane == .intentIntegration }?.candidatePassed == 1)
    }

    @Test func featureOnlyFixRetestUsesSealedInputWithoutNativeChild() throws {
        let caseID = UUID()
        let baseline = try snapshot(caseID: caseID, build: hash("a"), featureOutcome: .failed,
                                    includeNative: false)
        let candidate = try snapshot(caseID: caseID, build: hash("b"), featureOutcome: .passed,
                                     baselineID: baseline.plan.id, includeNative: false)
        let policy = ScenarioComparisonPolicy(mode: .compareAppChanges, baselineRunID: baseline.plan.id)
        let report = ScenarioExecutionComparison.compare(baseline: baseline,
                                                         candidate: candidate, policy: policy)
        #expect(report.isDirectlyComparable)
        #expect(report.summary.contains("Observed improvement"))
        var changedProfile = candidate
        changedProfile.plan.profile.destinationIdentifier = "other-device"
        #expect(!ScenarioExecutionComparison.compare(baseline: baseline,
            candidate: changedProfile, policy: policy).isDirectlyComparable)
    }

    @Test func completedFailedAssertionCanBeRetestedAfterNonzeroXCTestExit() throws {
        let caseID = UUID()
        var baseline = try snapshot(caseID: caseID, build: hash("a"), featureOutcome: .failed)
        let candidate = try snapshot(caseID: caseID, build: hash("b"), featureOutcome: .passed,
                                     baselineID: baseline.plan.id)
        baseline.runs[0].xctestExitCode = 1
        baseline.runs[0].outcome = .failed
        baseline.runs[0].laneResults[0].outcome = .failed
        baseline.runs[0].laneResults[0].assertionResults[0].passed = false
        let index = try #require(baseline.record.records.firstIndex {
            $0.coordinate.lane == .intentIntegration
        })
        baseline.record.records[index].laneResult = baseline.runs[0].laneResults[0]
        baseline.record = try .make(plan: baseline.plan, records: baseline.record.records)
        let report = ScenarioExecutionComparison.compare(
            baseline: baseline, candidate: candidate,
            policy: .init(mode: .compareAppChanges, baselineRunID: baseline.plan.id)
        )
        #expect(report.isDirectlyComparable)
        #expect(report.lanes.first { $0.lane == .intentIntegration }?.baselinePassed == 0)
    }

    @Test func changedRequirementsIncompleteRecordsAndBadProvenanceCannotClaimFix() throws {
        let caseID = UUID()
        let baseline = try snapshot(caseID: caseID, build: hash("a"), featureOutcome: .failed)
        let policy = ScenarioComparisonPolicy(mode: .compareAppChanges, baselineRunID: baseline.plan.id)
        let candidate = try snapshot(caseID: caseID, build: hash("b"), featureOutcome: .passed,
                                     baselineID: baseline.plan.id)

        var changedRequirements = candidate
        changedRequirements.plan.testContractDigest = hash("d")
        #expect(!ScenarioExecutionComparison.compare(baseline: baseline,
            candidate: changedRequirements, policy: policy).isDirectlyComparable)
        #expect(ScenarioExecutionComparison.compare(baseline: baseline,
            candidate: changedRequirements, policy: policy).summary.contains("Requirements changed"))

        var incomplete = candidate
        incomplete.record.records[0].state = .notRun
        incomplete.record.records[0].laneResult = nil
        incomplete.record.records[0].evidenceLaneResultID = nil
        incomplete.record = try .make(plan: incomplete.plan, records: incomplete.record.records)
        #expect(!ScenarioExecutionComparison.compare(baseline: baseline,
            candidate: incomplete, policy: policy).isDirectlyComparable)

        var unbound = candidate
        let featureIndex = try #require(unbound.record.records.firstIndex {
            $0.coordinate.lane == .appFeature
        })
        unbound.record.records[featureIndex].featureChild?.subjectInputDigest = nil
        let unsealedChild = try #require(unbound.record.records[featureIndex].featureChild)
        let child = try unsealedChild.sealed()
        unbound.record.records[featureIndex].featureChild = child
        unbound.record.records[featureIndex].evidenceDigest = child.digest
        unbound.record = try .make(plan: unbound.plan, records: unbound.record.records)
        #expect(!ScenarioExecutionComparison.compare(baseline: baseline,
            candidate: unbound, policy: policy).isDirectlyComparable)

        var changedMeasurement = candidate
        changedMeasurement.runs[0].measurementImplementation?.observerDigest = hash("c")
        #expect(ScenarioExecutionComparison.compare(baseline: baseline,
            candidate: changedMeasurement, policy: policy).summary.contains("Measurement changed"))

        var wrongNative = candidate
        wrongNative.runs[0].invocation.appProduct?.sha256 = hash("c")
        #expect(!ScenarioExecutionComparison.compare(baseline: baseline,
            candidate: wrongNative, policy: policy).isDirectlyComparable)
    }

    @Test func frozenPopulationAndPolicyPreventBorrowedGreenRows() throws {
        let caseID = UUID()
        let baseline = try snapshot(caseID: caseID, build: hash("a"), featureOutcome: .failed)
        let policy = ScenarioComparisonPolicy(mode: .compareAppChanges, baselineRunID: baseline.plan.id)
        var candidate = try snapshot(caseID: caseID, build: hash("b"), featureOutcome: .passed,
                                     baselineID: baseline.plan.id)
        candidate.plan.coordinates[0].repetition = 2
        #expect(!ScenarioExecutionComparison.compare(baseline: baseline,
            candidate: candidate, policy: policy).isDirectlyComparable)
        candidate = try snapshot(caseID: caseID, build: hash("b"), featureOutcome: .passed,
                                 baselineID: baseline.plan.id)
        candidate.plan.comparisonPolicy = nil
        #expect(!ScenarioExecutionComparison.compare(baseline: baseline,
            candidate: candidate, policy: policy).isDirectlyComparable)
        candidate = try snapshot(caseID: caseID, build: hash("b"), featureOutcome: .passed,
                                 baselineID: baseline.plan.id)
        candidate.record.records[0].laneResult?.outcome = .failed
        #expect(!ScenarioExecutionComparison.compare(baseline: baseline,
            candidate: candidate, policy: policy).isDirectlyComparable)
    }

    @Test func selectedSemanticAssessmentQualifiesOnlyWithTrustedSourceAndStableJudge() throws {
        let caseID = UUID()
        let definition = try semanticDefinition(caseID: caseID)
        var baseline = try semanticSnapshot(
            caseID: caseID, build: hash("a"), definition: definition
        )
        var candidate = try semanticSnapshot(
            caseID: caseID, build: hash("b"), definition: definition,
            baselineID: baseline.plan.id
        )
        let assertion = try #require(definition.assertions.first)
        let before = try semanticProjection(
            for: baseline, assertion: assertion, status: .failed
        )
        let after = try semanticProjection(
            for: candidate, assertion: assertion, status: .passed
        )
        let baselineLane = try #require(baseline.record.records.first?.laneResult)
        #expect(before.hasTrustedRequirementBinding(definition: definition, laneResult: baselineLane))
        var forgedReference = before
        forgedReference.verifiedReferenceDigest = hash("e")
        #expect(!forgedReference.hasTrustedRequirementBinding(definition: definition, laneResult: baselineLane))

        baseline.selectedAssessment = try .make(
            executionRecord: baseline.record, assessments: [before]
        )
        candidate.selectedAssessment = try .make(
            executionRecord: candidate.record, assessments: [after]
        )
        let policy = ScenarioComparisonPolicy(
            mode: .compareAppChanges, baselineRunID: baseline.plan.id
        )
        let report = ScenarioExecutionComparison.compare(
            baseline: baseline, candidate: candidate, policy: policy
        )
        #expect(report.isDirectlyComparable)
        #expect(report.summary.contains("Observed improvement"))
        #expect(report.lanes.first { $0.lane == .appFeature }?.baselinePassed == 0)
        #expect(report.lanes.first { $0.lane == .appFeature }?.candidatePassed == 1)

        var failedDeterministic = candidate
        let deterministic = try #require(definition.assertions.first {
            $0.kind == .returnedField
        })
        failedDeterministic.record.records[0].laneResult?.assertionResults = [
            .init(assertionID: assertion.id, passed: false,
                  message: "Semantic evidence requires a separate recorded assessment"),
            .init(assertionID: deterministic.id, passed: false,
                  observedValue: .string("Observed summary"), message: "Exact output failed")
        ]
        failedDeterministic.record = try .make(
            plan: failedDeterministic.plan, records: failedDeterministic.record.records
        )
        let failedProjection = try semanticProjection(
            for: failedDeterministic, assertion: assertion, status: .passed
        )
        failedDeterministic.selectedAssessment = try .make(
            executionRecord: failedDeterministic.record, assessments: [failedProjection]
        )
        let mixedReport = ScenarioExecutionComparison.compare(
            baseline: baseline, candidate: failedDeterministic, policy: policy
        )
        #expect(mixedReport.isDirectlyComparable)
        #expect(mixedReport.lanes.first { $0.lane == .appFeature }?.candidatePassed == 0)
        #expect(!mixedReport.summary.contains("Observed improvement"))

        var noSelection = candidate
        noSelection.selectedAssessment = nil
        #expect(!ScenarioExecutionComparison.compare(
            baseline: baseline, candidate: noSelection, policy: policy
        ).isDirectlyComparable)

        var changedJudge = after
        changedJudge.judgePolicyDigest = hash("e")
        candidate.selectedAssessment = try .make(
            executionRecord: candidate.record, assessments: [changedJudge]
        )
        let changedReport = ScenarioExecutionComparison.compare(
            baseline: baseline, candidate: candidate, policy: policy
        )
        #expect(!changedReport.isDirectlyComparable)
        #expect(changedReport.summary.contains("Measurement changed"))

        var forged = after
        forged.verifiedReferenceDigest = hash("e")
        candidate.selectedAssessment = try .make(
            executionRecord: candidate.record, assessments: [forged]
        )
        #expect(!ScenarioExecutionComparison.compare(
            baseline: baseline, candidate: candidate, policy: policy
        ).isDirectlyComparable)
    }

    @Test func nativeNeedsReviewCanUseBoundSelectedAssessment() throws {
        let caseID = UUID()
        var definition = try semanticDefinition(caseID: caseID)
        definition.coverage.intentIntegration = .required
        definition.assertions[0].applicableLanes = [.appFeature, .intentIntegration]
        definition.assertions[1].applicableLanes = [.appFeature, .intentIntegration]
        definition = try definition.frozen()
        let assertion = definition.assertions[0]
        var baseline = try nativeSemanticSnapshot(
            caseID: caseID, build: hash("a"), definition: definition
        )
        var candidate = try nativeSemanticSnapshot(
            caseID: caseID, build: hash("b"), definition: definition,
            baselineID: baseline.plan.id
        )
        baseline.selectedAssessment = try .make(
            executionRecord: baseline.record,
            assessments: try [.appFeature, .intentIntegration].map {
                try semanticProjection(for: baseline, assertion: assertion,
                                       status: .failed, lane: $0)
            }
        )
        candidate.selectedAssessment = try .make(
            executionRecord: candidate.record,
            assessments: try [.appFeature, .intentIntegration].map {
                try semanticProjection(for: candidate, assertion: assertion,
                                       status: .passed, lane: $0)
            }
        )
        let report = ScenarioExecutionComparison.compare(
            baseline: baseline, candidate: candidate,
            policy: .init(mode: .compareAppChanges, baselineRunID: baseline.plan.id)
        )
        #expect(report.isDirectlyComparable)
        #expect(report.lanes.first { $0.lane == .intentIntegration }?.candidatePassed == 1)
        #expect(report.summary.contains("Observed improvement"))
    }

    private func semanticDefinition(caseID: UUID) throws -> ScenarioDefinition {
        var definition = ScenarioDefinition.starter()
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.id = caseID
        definition.target.bundleIdentifier = "example.App"
        definition.fixture.digest = hash("4")
        definition.coverage.appFeature = .required
        definition.coverage.intentIntegration = .notApplicable
        definition.coverage.siri = .notApplicable
        definition.featureBinding = .init(
            featureID: "summarize", interfaceDigest: hash("f"),
            inputMapping: [.init(featureInputName: "text", value: .string("Source text"))],
            outputProjections: [.init(name: "response", type: .primitive(.string))]
        )
        definition.assertions = [
            .init(kind: .semanticRubric, observationKey: "feature.response",
                  expectedValue: .string("Reference summary"),
                  explanation: "Check the captured summary.", applicableLanes: [.appFeature]),
            .init(kind: .returnedField, observationKey: "feature.response",
                  expectedValue: .string("Observed summary"),
                  explanation: "The response is captured exactly.", applicableLanes: [.appFeature])
        ]
        return try definition.frozen()
    }

    private func semanticSnapshot(
        caseID: UUID, build: String, definition: ScenarioDefinition,
        baselineID: UUID? = nil
    ) throws -> ScenarioExecutionComparison.Snapshot {
        var value = try snapshot(
            caseID: caseID, build: build, featureOutcome: .needsReview,
            baselineID: baselineID, includeNative: false
        )
        value.plan.definitionDigest = definition.definitionDigest
        value.plan.testContractDigest = try #require(definition.testContractDigest)
        value.plan.definitionVersion = definition.version
        let semantic = try #require(definition.assertions.first { $0.kind == .semanticRubric })
        let deterministic = try #require(definition.assertions.first { $0.kind == .returnedField })
        value.record.records[0].laneResult?.assertionResults = [
            .init(assertionID: semantic.id, passed: false,
                  message: "Semantic evidence requires a separate recorded assessment"),
            .init(assertionID: deterministic.id, passed: true,
                  observedValue: .string("Observed summary"), message: "Exact output matched")
        ]
        value.record = try .make(plan: value.plan, records: value.record.records)
        value.definition = definition
        return value
    }

    private func nativeSemanticSnapshot(
        caseID: UUID, build: String, definition: ScenarioDefinition,
        baselineID: UUID? = nil
    ) throws -> ScenarioExecutionComparison.Snapshot {
        var value = try snapshot(
            caseID: caseID, build: build, featureOutcome: .needsReview,
            baselineID: baselineID
        )
        value.plan.definitionDigest = definition.definitionDigest
        value.plan.testContractDigest = try #require(definition.testContractDigest)
        value.plan.definitionVersion = definition.version
        let semantic = definition.assertions[0]
        let deterministic = definition.assertions[1]
        for index in value.record.records.indices {
            var lane = try #require(value.record.records[index].laneResult)
            lane.outcome = .needsReview
            lane.observations["feature.response"] = .string("Observed summary")
            lane.assertionResults = [
                .init(assertionID: semantic.id, passed: false,
                      message: "Semantic evidence requires a separate recorded assessment"),
                .init(assertionID: deterministic.id, passed: true,
                      observedValue: .string("Observed summary"), message: "Exact output matched")
            ]
            value.record.records[index].laneResult = lane
            if lane.lane == .intentIntegration {
                value.record.records[index].evidenceDigest = definition.definitionDigest
                value.runs[0].laneResults = [lane]
            }
        }
        value.runs[0].scenarioDigest = definition.definitionDigest
        value.runs[0].invocation.scenarioDigest = definition.definitionDigest
        value.runs[0].testContractDigest = definition.testContractDigest
        value.runs[0].outcome = .needsReview
        value.record = try .make(plan: value.plan, records: value.record.records)
        value.definition = definition
        return value
    }

    private func semanticProjection(
        for snapshot: ScenarioExecutionComparison.Snapshot,
        assertion: ScenarioAssertion,
        status: ScenarioSelectedAssessmentStatus,
        lane selectedLane: ScenarioLane = .appFeature
    ) throws -> ScenarioSelectedAssessmentProjection {
        let item = try #require(snapshot.record.records.first {
            $0.coordinate.lane == selectedLane
        })
        let lane = try #require(item.laneResult)
        let runID = try #require(item.evidenceRunID)
        guard case .string(let output)? = lane.observations[assertion.observationKey] else {
            throw ScenarioPersistenceError.invalidRun("semantic observation")
        }
        let reference: String
        if case .string(let value)? = assertion.expectedValue {
            reference = value
        } else {
            throw ScenarioPersistenceError.invalidRun("semantic reference")
        }
        var projection = ScenarioSelectedAssessmentProjection(
            scenarioRunID: runID, laneResultID: lane.id,
            caseID: item.coordinate.caseID, lane: item.coordinate.lane,
            attempt: item.coordinate.repetition, assertionID: assertion.id,
            observationKey: assertion.observationKey, selectedAssessmentID: UUID(),
            status: status, rawOutputDigest: sha(output),
            verifiedReferenceDigest: sha(reference),
            rubricDigest: sha(assertion.explanation.trimmingCharacters(in: .whitespacesAndNewlines)),
            sourceBindingDigest: "", scoringContractDigest: hash("a"),
            judgePolicyDigest: hash("b"), judgePromptVersion: "judge-v1",
            requestedJudgeModelID: "judge-model", reportedJudgeModelID: "judge-model",
            judgeConnectionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        )
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
            scenarioRunID: projection.scenarioRunID,
            laneResultID: projection.laneResultID, caseID: projection.caseID,
            lane: projection.lane, attempt: projection.attempt,
            assertionID: projection.assertionID,
            observationKey: projection.observationKey,
            rawOutputDigest: projection.rawOutputDigest,
            verifiedReferenceDigest: projection.verifiedReferenceDigest,
            rubricDigest: projection.rubricDigest
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        projection.sourceBindingDigest = sha(try encoder.encode(seal))
        return projection
    }

    private func sha(_ value: String) -> String { sha(Data(value.utf8)) }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func snapshot(
        caseID: UUID, build: String, featureOutcome: ScenarioOutcome,
        baselineID: UUID? = nil, includeNative: Bool = true
    ) throws -> ScenarioExecutionComparison.Snapshot {
        let now = Date(timeIntervalSince1970: 1_000)
        let feature = ScenarioPlannedCoordinate(id: UUID(), caseID: caseID, lane: .appFeature,
                                                repetition: 1, required: true)
        let intent = ScenarioPlannedCoordinate(id: UUID(), caseID: caseID, lane: .intentIntegration,
                                               repetition: 1, required: true)
        let plan = ScenarioExecutionPlan(
            id: UUID(), definitionID: caseID, definitionVersion: 1,
            definitionDigest: hash("1"), testContractDigest: hash("2"),
            profile: .init(id: UUID(), projectPath: "/project/App.xcodeproj", scheme: "App",
                           testTarget: "AppTests", destinationIdentifier: "device",
                           signingSelection: nil),
            appProductDigest: build, testProductDigest: hash("3"),
            fixtureContractDigest: hash("4"), coordinates: includeNative ? [feature, intent] : [feature],
            comparisonPolicy: baselineID.map {
                .init(mode: .compareAppChanges, baselineRunID: $0)
            }, createdAt: now, sourceInputsDigest: hash("5"),
            runnerBuildID: build, runnerID: UUID()
        )
        let featureRunID = UUID()
        let featureLane = ScenarioLaneResult(
            caseID: caseID, attempt: 1, lane: .appFeature,
            executionStatus: .completed, outcome: featureOutcome,
            startedAt: now, completedAt: now,
            observations: ["feature.response": .string("Observed summary")],
            assertionResults: [.init(assertionID: UUID(), passed: featureOutcome == .passed,
                                     observedValue: .string("Observed summary"), message: "checked")]
        )
        let measurement = ScenarioMeasurementImplementation(
            observerID: "observer", observerDigest: hash("6"),
            evaluatorID: "evaluator", evaluatorDigest: hash("7")
        )
        var featureChild = ScenarioFeatureChildEvidence(
            runID: featureRunID, sampleID: UUID(), startedAt: now, completedAt: now,
            caseID: caseID, attempt: 1, response: "Observed summary",
            encodedOutput: nil, encodedOutputTypeName: nil,
            outputMetadata: ["intentlab.subjectInputDigest": hash("8")],
            errorCategory: nil, errorMessage: nil,
            appBundleIdentifier: "example.App", featureID: "summarize", featureVersion: "1",
            checkedAppProductDigest: build, runnerBuildID: build,
            fixtureContractDigest: hash("4"), subjectInputDigest: hash("8"), digest: ""
        )
        featureChild.measurementImplementation = measurement
        featureChild = try featureChild.sealed()
        let featureRecord = ScenarioExecutionCoordinateRecord(
            coordinate: feature, state: .completed,
            evidenceRunID: featureRunID, evidenceLaneResultID: featureLane.id,
            detail: nil, laneResult: featureLane, evidenceDigest: featureChild.digest,
            featureChild: featureChild
        )
        if !includeNative {
            let record = try ScenarioExecutionRecord.make(plan: plan, records: [featureRecord])
            return .init(plan: plan, record: record, runs: [])
        }
        let nativeLane = ScenarioLaneResult(
            caseID: caseID, attempt: 1, lane: .intentIntegration,
            executionStatus: .completed, outcome: .passed,
            startedAt: now, completedAt: now,
            observations: ["summary": .string("Observed summary")],
            assertionResults: [.init(assertionID: UUID(), passed: true,
                                     observedValue: .string("Observed summary"), message: "checked")]
        )
        let runID = UUID()
        let invocation = ScenarioInvocationIdentity(
            id: runID, nonce: UUID().uuidString, issuedAt: now,
            testIdentity: .init(bundleIdentifier: "example.AppTests", className: "ScenarioTests",
                                methodName: "testIntent"), harnessVersion: "intent-lab-v3",
            destinationIdentifier: "device", scenarioDigest: plan.definitionDigest,
            resultBundleIdentity: UUID().uuidString,
            appProduct: .init(bundleIdentifier: "example.App", executableName: "App", sha256: build),
            testProduct: .init(bundleIdentifier: "example.AppTests", executableName: "AppTests",
                               sha256: plan.testProductDigest)
        )
        let environment = ScenarioEnvironment(
            xcodeVersion: "27", sdkVersion: "27", deviceModel: "iPhone",
            operatingSystem: "iOS 27", operatingSystemBuild: "27A1",
            languageCode: "en", regionCode: "GB", timeZoneIdentifier: "UTC",
            siriConfiguration: "enabled", siriConfigurationSource: .applicationInstrumentation,
            executedAt: now
        )
        var run = ScenarioRun(
            id: runID, scenarioID: caseID, scenarioVersion: plan.definitionVersion,
            scenarioDigest: plan.definitionDigest, invocation: invocation,
            startedAt: now, completedAt: now, environment: environment,
            executionStatus: .completed, outcome: .passed,
            laneResults: [nativeLane], linkedFeatureRunID: nil, importedAt: now
        )
        run.scenarioSchemaVersion = ScenarioDefinition.stableSchemaVersion
        run.testContractDigest = plan.testContractDigest
        run.fixture = .init(id: "fixture", version: "1", digest: plan.fixtureContractDigest,
                            isSynthetic: true, preparationOperation: "prepare", cleanupOperation: "cleanup")
        run.xctestExitCode = 0
        run.executedTestCount = 1
        run.measurementImplementation = measurement
        run.comparisonEnvironmentIdentity = .init(profileID: "iphone-en", profileDigest: hash("9"))
        run.subjectImplementation = .init(sourceRevision: build, promptDigest: hash("0"), modelRevision: nil)
        let nativeRecord = ScenarioExecutionCoordinateRecord(
            coordinate: intent, state: .completed, evidenceRunID: runID,
            evidenceLaneResultID: nativeLane.id, detail: nil, laneResult: nativeLane,
            evidenceDigest: plan.definitionDigest
        )
        let record = try ScenarioExecutionRecord.make(plan: plan, records: [featureRecord, nativeRecord])
        return .init(plan: plan, record: record, runs: [run])
    }

    private func hash(_ nibble: String) -> String { String(repeating: nibble, count: 64) }
}
