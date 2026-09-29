import CryptoKit
import Foundation
import Testing
@testable import FoundationEvals

struct IntentEvidenceBundleTests {
    @Test func exploratoryCheckCannotQualifyInGUIOrOffline() throws {
        let fixture = try nativeBundle(
            observed: "packing-001", claimedOutcome: .passed,
            executedTestCount: 1, xctestExitCode: 0, purpose: .exploratory
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let decision = IntentEvidenceQualification.qualify(
            fixture.snapshot.cases[0], requirement: fixture.trusted.cases[0],
            referenceTime: Date(timeIntervalSince1970: 100)
        )
        #expect(decision.incompleteEvidence.contains {
            $0 == "Exploratory checks do not qualify as release requirements."
        })
        let offline = try IntentEvidenceChecker.check(
            bundle: fixture.bundle, requirements: fixture.requirements,
            expectedSource: "revision-a", expectedAppDigest: String(repeating: "a", count: 64),
            policy: IntentEvidenceChecker.policyID,
            referenceTime: Date(timeIntervalSince1970: 100)
        )
        #expect(offline.exitCode == 20)
        #expect(String(decoding: offline.json, as: UTF8.self).contains(
            "Exploratory checks do not qualify as release requirements."
        ))
    }

    @Test func legacyPlanCannotClaimAnUnfrozenGitSource() throws {
        let fixture = try nativeBundle(observed: "packing-001", claimedOutcome: .passed,
                                       executedTestCount: 1, xctestExitCode: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var snapshot = fixture.snapshot
        snapshot.cases[0].plan.sourceRevision = nil
        let inputs = try #require(snapshot.cases[0].plan.sourceInputsDigest)
        snapshot.sourceRevision = "inputs-sha256:\(inputs)"
        try FileManager.default.removeItem(at: fixture.bundle)
        try IntentEvidenceBundle.export(snapshot, to: fixture.bundle)
        let accepted = try IntentEvidenceChecker.check(
            bundle: fixture.bundle, requirements: fixture.requirements,
            expectedSource: snapshot.sourceRevision,
            expectedAppDigest: String(repeating: "a", count: 64),
            policy: IntentEvidenceChecker.policyID,
            referenceTime: Date(timeIntervalSince1970: 100)
        )
        #expect(accepted.exitCode == 0)

        snapshot.sourceRevision = "git:\(String(repeating: "a", count: 40))"
        try FileManager.default.removeItem(at: fixture.bundle)
        try IntentEvidenceBundle.export(snapshot, to: fixture.bundle)
        #expect(throws: IntentEvidenceBundleError.self) {
            try IntentEvidenceChecker.check(
                bundle: fixture.bundle, requirements: fixture.requirements,
                expectedSource: snapshot.sourceRevision,
                expectedAppDigest: String(repeating: "a", count: 64),
                policy: IntentEvidenceChecker.policyID,
                referenceTime: Date(timeIntervalSince1970: 100)
            )
        }
    }

    @Test func frozenPlanSourceMustMatchBundleSource() throws {
        let fixture = try fixtureBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.bundle)
        var snapshot = fixture.snapshot
        snapshot.cases[0].plan.sourceRevision = "git:\(String(repeating: "a", count: 40))"
        try IntentEvidenceBundle.export(snapshot, to: fixture.bundle)
        #expect(throws: IntentEvidenceBundleError.self) {
            try IntentEvidenceChecker.check(
                bundle: fixture.bundle, requirements: fixture.requirements,
                expectedSource: "revision-a", expectedAppDigest: String(repeating: "a", count: 64),
                policy: IntentEvidenceChecker.policyID,
                referenceTime: Date(timeIntervalSince1970: 100)
            )
        }
    }

    @Test func duplicateCaseIDsInChecksummedBundleReturnValidationError() throws {
        let fixture = try fixtureBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let requirementsURL = fixture.bundle.appending(path: "requirements/collection.json")
        var requirements = try JSONDecoder().decode(
            IntentEvidenceRequirements.self, from: Data(contentsOf: requirementsURL)
        )
        requirements.cases.append(requirements.cases[0])
        let bytes = try encode(requirements)
        try bytes.write(to: requirementsURL, options: .atomic)
        let manifestURL = fixture.bundle.appending(path: "manifest.json")
        var manifest = try JSONDecoder().decode(
            IntentEvidenceBundleManifest.self, from: Data(contentsOf: manifestURL)
        )
        let index = try #require(manifest.files.firstIndex { $0.path == "requirements/collection.json" })
        manifest.files[index].bytes = bytes.count
        manifest.files[index].sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try encode(manifest).write(to: manifestURL, options: .atomic)
        #expect(throws: IntentEvidenceBundleError.self) {
            try IntentEvidenceChecker.check(
                bundle: fixture.bundle, requirements: fixture.requirements,
                expectedSource: "revision-a", expectedAppDigest: String(repeating: "a", count: 64),
                policy: IntentEvidenceChecker.policyID,
                referenceTime: Date(timeIntervalSince1970: 100)
            )
        }
    }

    @Test func packagedCommandChecksTrustedSnapshotWhenConfigured() throws {
        guard let executable = ProcessInfo.processInfo.environment["INTENTS_EVIDENCE_CLI_BINARY"] else {
            return
        }
        let fixture = try nativeBundle(observed: "packing-001", claimedOutcome: .passed,
                                       executedTestCount: 1, xctestExitCode: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "check", "--bundle", fixture.bundle.path,
            "--requirements", fixture.requirements.path,
            "--expected-source", "revision-a",
            "--expected-app-digest", String(repeating: "a", count: 64),
            "--policy", IntentEvidenceChecker.policyID,
            "--format", "json", "--reference-time", "1970-01-01T00:01:40Z"
        ]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(process.terminationStatus == 0)
        #expect(object["requirementsMet"] as? Bool == true)
    }

    @Test func incompleteFrozenCoordinateCannotPassOffline() throws {
        let fixture = try fixtureBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try IntentEvidenceChecker.check(
            bundle: fixture.bundle, requirements: fixture.requirements,
            expectedSource: "revision-a", expectedAppDigest: String(repeating: "a", count: 64), policy: IntentEvidenceChecker.policyID,
            referenceTime: Date(timeIntervalSince1970: 100)
        )
        #expect(result.exitCode == 20)
        let object = try #require(JSONSerialization.jsonObject(with: result.json) as? [String: Any])
        #expect(object["requirementsMet"] as? Bool == false)
        #expect((object["incompleteEvidence"] as? [String])?.isEmpty == false)
    }

    @Test func exportedPassFlagCannotOverrideMissingChildEvidence() throws {
        let fixture = try fixtureBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.bundle)
        var snapshot = fixture.snapshot
        snapshot.report = Data(#"{"passed":true,"outcome":"passed"}"#.utf8)
        try IntentEvidenceBundle.export(snapshot, to: fixture.bundle)
        let result = try IntentEvidenceChecker.check(
            bundle: fixture.bundle, requirements: fixture.requirements,
            expectedSource: "revision-a", expectedAppDigest: String(repeating: "a", count: 64), policy: IntentEvidenceChecker.policyID,
            referenceTime: Date(timeIntervalSince1970: 100)
        )
        #expect(result.exitCode == 20)
    }

    @Test func nonzeroNativeAssertionFailureRemainsIncompleteButVisible() throws {
        let passed = try nativeBundle(observed: "packing-001", claimedOutcome: .passed,
                                      executedTestCount: 1, xctestExitCode: 0)
        defer { try? FileManager.default.removeItem(at: passed.root) }
        let passResult = try IntentEvidenceChecker.check(
            bundle: passed.bundle, requirements: passed.requirements,
            expectedSource: "revision-a", expectedAppDigest: String(repeating: "a", count: 64), policy: IntentEvidenceChecker.policyID,
            referenceTime: Date(timeIntervalSince1970: 100)
        )
        #expect(passResult.exitCode == 0)

        let failed = try nativeBundle(observed: "wrong-note", claimedOutcome: .failed,
                                      executedTestCount: 1, xctestExitCode: 1,
                                      actionFailureReason: .wrongOutcome)
        defer { try? FileManager.default.removeItem(at: failed.root) }
        let failResult = try IntentEvidenceChecker.check(
            bundle: failed.bundle, requirements: failed.requirements,
            expectedSource: "revision-a", expectedAppDigest: String(repeating: "a", count: 64), policy: IntentEvidenceChecker.policyID,
            referenceTime: Date(timeIntervalSince1970: 100)
        )
        #expect(failResult.exitCode == 20)
        let object = try #require(JSONSerialization.jsonObject(with: failResult.json) as? [String: Any])
        #expect((object["requiredFailures"] as? [String])?.isEmpty == false)
        #expect((object["incompleteEvidence"] as? [String])?.isEmpty == false)
    }

    @Test func mixedBusinessAndXCTestFailureRemainsIncompleteAndVisible() throws {
        for reason in [ScenarioActionFailureReason.wrongAction, .wrongOutcome] {
            let fixture = try nativeBundle(
                observed: "wrong-note", claimedOutcome: .failed,
                executedTestCount: 1, xctestExitCode: 1,
                actionFailureReason: reason
            )
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let result = try IntentEvidenceChecker.check(
                bundle: fixture.bundle, requirements: fixture.requirements,
                expectedSource: "revision-a", expectedAppDigest: String(repeating: "a", count: 64),
                policy: IntentEvidenceChecker.policyID,
                referenceTime: Date(timeIntervalSince1970: 100)
            )
            #expect(result.exitCode == 20)
            let object = try #require(JSONSerialization.jsonObject(with: result.json) as? [String: Any])
            #expect((object["incompleteEvidence"] as? [String])?.isEmpty == false)
            #expect((object["requiredFailures"] as? [String])?.isEmpty == false)
        }

        let unknown = try nativeBundle(
            observed: "wrong-note", claimedOutcome: .failed,
            executedTestCount: 1, xctestExitCode: 1
        )
        defer { try? FileManager.default.removeItem(at: unknown.root) }
        let result = try IntentEvidenceChecker.check(
            bundle: unknown.bundle, requirements: unknown.requirements,
            expectedSource: "revision-a", expectedAppDigest: String(repeating: "a", count: 64),
            policy: IntentEvidenceChecker.policyID,
            referenceTime: Date(timeIntervalSince1970: 100)
        )
        #expect(result.exitCode == 20)
        let object = try #require(JSONSerialization.jsonObject(with: result.json) as? [String: Any])
        #expect((object["incompleteEvidence"] as? [String])?.isEmpty == false)
        #expect((object["requiredFailures"] as? [String])?.isEmpty == false)
    }

    @Test func zeroNativeTestsAndSpoofedPassNeverQualify() throws {
        let skipped = try nativeBundle(observed: "packing-001", claimedOutcome: .passed,
                                       executedTestCount: 0, xctestExitCode: 0)
        defer { try? FileManager.default.removeItem(at: skipped.root) }
        let skippedResult = try IntentEvidenceChecker.check(
            bundle: skipped.bundle, requirements: skipped.requirements,
            expectedSource: "revision-a", expectedAppDigest: String(repeating: "a", count: 64), policy: IntentEvidenceChecker.policyID,
            referenceTime: Date(timeIntervalSince1970: 100)
        )
        #expect(skippedResult.exitCode == 20)

        let spoofed = try nativeBundle(observed: "wrong-note", claimedOutcome: .passed,
                                       executedTestCount: 1, xctestExitCode: 0)
        defer { try? FileManager.default.removeItem(at: spoofed.root) }
        let spoofedResult = try IntentEvidenceChecker.check(
            bundle: spoofed.bundle, requirements: spoofed.requirements,
            expectedSource: "revision-a", expectedAppDigest: String(repeating: "a", count: 64), policy: IntentEvidenceChecker.policyID,
            referenceTime: Date(timeIntervalSince1970: 100)
        )
        #expect(spoofedResult.exitCode != 0)
    }

    @Test func selectedRerunCannotPassTheFullTrustedCollection() throws {
        let fixture = try nativeBundle(observed: "packing-001", claimedOutcome: .passed,
                                       executedTestCount: 1, xctestExitCode: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = fixture.trusted.cases[0].definition
        var second = first
        second.id = UUID()
        second.name = "Another note"
        second = try second.frozen()
        let collection = try ScenarioCollection(
            projectID: UUID(), name: "Notes checks",
            members: [try .init(definition: first), try .init(definition: second)]
        )
        let selected = fixture.snapshot.cases[0]
        let now = Date(timeIntervalSince1970: 100)
        var batch = ScenarioCollectionBatchManifest(
            id: UUID(), collectionID: collection.id, collectionVersion: collection.version,
            membershipDigest: collection.membershipDigest,
            appProductDigest: selected.plan.appProductDigest, scope: .selected,
            priorBatchID: nil,
            cases: [.init(member: collection.members[0], executionPlanID: selected.plan.id,
                          fixtureContractDigest: first.fixture.digest,
                          targetBundleIdentifier: first.target.bundleIdentifier,
                          featureID: nil, expectedSubjectInputDigest: nil)],
            coordinates: selected.plan.coordinates, createdAt: now, manifestDigest: ""
        )
        batch.manifestDigest = try batch.calculatedDigest()
        let result = ScenarioCollectionBatchResult(
            id: batch.id, manifestID: batch.id,
            executions: [selected.record], recordedAt: Date(timeIntervalSince1970: 101)
        )
        var trusted = fixture.trusted
        trusted.collectionID = collection.id.uuidString
        trusted.cases.append(.init(required: true, definition: second))
        var snapshot = fixture.snapshot
        snapshot.requirements = trusted
        snapshot.collection = collection
        snapshot.batchManifest = batch
        snapshot.batchResult = result
        try FileManager.default.removeItem(at: fixture.bundle)
        try IntentEvidenceBundle.export(snapshot, to: fixture.bundle)
        try encode(trusted).write(to: fixture.requirements, options: .atomic)

        let check = try IntentEvidenceChecker.check(
            bundle: fixture.bundle, requirements: fixture.requirements,
            expectedSource: "revision-a", expectedAppDigest: String(repeating: "a", count: 64), policy: IntentEvidenceChecker.policyID,
            referenceTime: now
        )
        #expect(check.exitCode == 20)
        let object = try #require(JSONSerialization.jsonObject(with: check.json) as? [String: Any])
        #expect(object["requirementsMet"] as? Bool == false)
        #expect((object["cases"] as? [[String: Any]])?.count == 2)
        #expect((object["cases"] as? [[String: Any]])?.contains(where: {
            $0["notRun"] as? Bool == true
        }) == true)
        #expect((object["incompleteEvidence"] as? [String])?.contains(where: {
            $0.contains("Partial batch scope")
        }) == true)
    }

    @Test func selectedSemanticPassCannotOverrideDeterministicFailure() throws {
        let fixture = try nativeBundle(observed: "wrong-note", claimedOutcome: .failed,
                                       executedTestCount: 1, xctestExitCode: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var item = fixture.snapshot.cases[0]
        var definition = item.definition
        definition.checkMode = .behaviour
        definition.requiredClaims = [.executionCompleted, .returnedValueChecked, .applicationStateChecked]
        definition.observationPlan?.append(.init(
            id: "summaryText", source: .testOnlyIntent,
            operationID: "readSummary", selector: nil
        ))
        let semantic = ScenarioAssertion(
            kind: .semanticRubric, observationKey: "summaryText",
            expectedValue: .string("expected summary"),
            explanation: " Preserve the important source facts. ",
            applicableLanes: [.intentIntegration]
        )
        definition.assertions.append(semantic)
        definition = try definition.frozen()
        item.definition = definition
        item.plan.definitionDigest = definition.definitionDigest
        item.plan.testContractDigest = try #require(definition.testContractDigest)
        var run = item.runs[0]
        run.scenarioDigest = definition.definitionDigest
        run.testContractDigest = definition.testContractDigest
        run.invocation.scenarioDigest = definition.definitionDigest
        run.negotiatedCapabilities = ScenarioHarnessCapabilities.required(for: definition).sorted()
        var lane = run.laneResults[0]
        lane.observations["summaryText"] = .string("observed summary")
        lane.observationSources?["summaryText"] = .applicationInstrumentation
        lane.assertionResults.append(.init(
            assertionID: semantic.id, passed: false,
            observedValue: .string("observed summary"), message: "Awaiting selected assessment"
        ))
        run.laneResults = [lane]
        item.runs = [run]
        item.journals[0].invocation = run.invocation
        var terminal = item.record.records[0]
        terminal.laneResult = lane
        let rawDigest = sha256("observed summary")
        let referenceDigest = sha256("expected summary")
        let rubricDigest = sha256("Preserve the important source facts.")
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
            scenarioRunID: run.id, laneResultID: lane.id, caseID: definition.id,
            lane: .intentIntegration, attempt: 1, assertionID: semantic.id,
            observationKey: "summaryText", rawOutputDigest: rawDigest,
            verifiedReferenceDigest: referenceDigest, rubricDigest: rubricDigest
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sourceDigest = SHA256.hash(data: try encoder.encode(seal))
            .map { String(format: "%02x", $0) }.joined()
        let scoringDigest = String(repeating: "1", count: 64)
        let judgeDigest = String(repeating: "2", count: 64)
        let projection = ScenarioSelectedAssessmentProjection(
            scenarioRunID: run.id, laneResultID: lane.id, caseID: definition.id,
            lane: .intentIntegration, attempt: 1, assertionID: semantic.id,
            observationKey: "summaryText", selectedAssessmentID: UUID(),
            status: .passed, rawOutputDigest: rawDigest,
            verifiedReferenceDigest: referenceDigest, rubricDigest: rubricDigest,
            sourceBindingDigest: sourceDigest, scoringContractDigest: scoringDigest,
            judgePolicyDigest: judgeDigest, judgePromptVersion: "v1",
            requestedJudgeModelID: "test-judge", reportedJudgeModelID: nil,
            judgeConnectionID: nil
        )
        #expect(projection.hasTrustedRequirementBinding(definition: definition, laneResult: lane))
        item.record = try ScenarioExecutionRecord.make(
            plan: item.plan, records: [terminal], selectedAssessments: [projection],
            completedAt: item.record.completedAt
        )
        let requirement = IntentEvidenceRequirements.CaseRequirement(
            required: true, definition: definition,
            semanticPolicy: .init(scoringContractDigest: scoringDigest,
                                  judgePolicyDigest: judgeDigest)
        )
        let decision = IntentEvidenceQualification.qualify(
            item, requirement: requirement, referenceTime: Date(timeIntervalSince1970: 100)
        )
        #expect(decision.report?.outcome != .passed)
        #expect(decision.requiredFailures.contains(where: { $0.contains("failed its observed requirement") }))
        #expect(decision.incompleteEvidence.contains(where: { $0.contains("retained semantic assessment") }))

        // A producer can seal a syntactically valid artifact around invented
        // assessment bytes. The imported checker must still reject its claim.
        item.retainedAssessments = [try ScenarioRetainedAssessmentArtifact.make(
            projection: projection, retainedAssessmentJSON: Data("{}".utf8)
        )]
        let bundle = fixture.root.appending(path: "invented-assessment.intentlabrun")
        let trustedURL = fixture.root.appending(path: "semantic-requirements.json")
        let trusted = IntentEvidenceRequirements(
            collectionID: "native-regressions", cases: [requirement]
        )
        try encode(trusted).write(to: trustedURL, options: .atomic)
        try IntentEvidenceBundle.export(.init(
            requirements: trusted, cases: [item], sourceRevision: "revision-a"
        ), to: bundle)
        let offline = try IntentEvidenceChecker.check(
            bundle: bundle, requirements: trustedURL,
            expectedSource: "revision-a", expectedAppDigest: String(repeating: "a", count: 64),
            policy: IntentEvidenceChecker.policyID,
            referenceTime: Date(timeIntervalSince1970: 100)
        )
        #expect(offline.exitCode == 20)
        #expect(String(decoding: offline.json, as: UTF8.self).contains("retained semantic assessment"))
    }

    @Test func externalSourceAndRequirementsAreMandatory() throws {
        let fixture = try fixtureBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(throws: Error.self) {
            try IntentEvidenceChecker.check(
                bundle: fixture.bundle, requirements: fixture.requirements,
                expectedSource: "different-revision", expectedAppDigest: String(repeating: "a", count: 64), policy: IntentEvidenceChecker.policyID,
                referenceTime: Date(timeIntervalSince1970: 100)
            )
        }
        #expect(throws: Error.self) {
            try IntentEvidenceChecker.check(
                bundle: fixture.bundle, requirements: fixture.requirements,
                expectedSource: "revision-a", expectedAppDigest: String(repeating: "a", count: 64), policy: "unknown-policy",
                referenceTime: Date(timeIntervalSince1970: 100)
            )
        }
        var trusted = fixture.trusted
        trusted.cases[0].required = false
        try encode(trusted).write(to: fixture.requirements, options: .atomic)
        #expect(throws: Error.self) {
            try IntentEvidenceChecker.check(
                bundle: fixture.bundle, requirements: fixture.requirements,
                expectedSource: "revision-a", expectedAppDigest: String(repeating: "a", count: 64), policy: IntentEvidenceChecker.policyID,
                referenceTime: Date(timeIntervalSince1970: 100)
            )
        }
    }

    @Test func changedExpectationsFailEvenWhenBothDefinitionsAreRehashed() throws {
        let fixture = try fixtureBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var trusted = fixture.trusted
        trusted.cases[0].definition.goal.expectedBehavior = "A different outcome"
        trusted.cases[0].definition = try trusted.cases[0].definition.frozen()
        try encode(trusted).write(to: fixture.requirements, options: .atomic)
        #expect(throws: Error.self) {
            try IntentEvidenceChecker.check(
                bundle: fixture.bundle, requirements: fixture.requirements,
                expectedSource: "revision-a", expectedAppDigest: String(repeating: "a", count: 64), policy: IntentEvidenceChecker.policyID,
                referenceTime: Date(timeIntervalSince1970: 100)
            )
        }
    }

    @Test func comparisonRejectsProducerSelectedSourceIdentity() throws {
        let fixture = try fixtureBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(throws: Error.self) {
            try IntentEvidenceChecker.compare(
                baseline: fixture.bundle, candidate: fixture.bundle,
                requirements: fixture.requirements, baselineSource: "revision-a",
                candidateSource: "externally-expected-revision",
                baselineAppDigest: String(repeating: "a", count: 64),
                candidateAppDigest: String(repeating: "a", count: 64),
                policy: IntentEvidenceChecker.policyID, mode: "app-change",
                referenceTime: Date(timeIntervalSince1970: 100)
            )
        }
    }

    @Test func externallyExpectedAppBuildRejectsSubstitutedBundle() throws {
        let fixture = try nativeBundle(observed: "packing-001", claimedOutcome: .passed,
                                       executedTestCount: 1, xctestExitCode: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(throws: Error.self) {
            try IntentEvidenceChecker.check(
                bundle: fixture.bundle, requirements: fixture.requirements,
                expectedSource: "revision-a", expectedAppDigest: String(repeating: "9", count: 64),
                policy: IntentEvidenceChecker.policyID,
                referenceTime: Date(timeIntervalSince1970: 100)
            )
        }
        #expect(throws: Error.self) {
            try IntentEvidenceChecker.compare(
                baseline: fixture.bundle, candidate: fixture.bundle,
                requirements: fixture.requirements,
                baselineSource: "revision-a", candidateSource: "revision-a",
                baselineAppDigest: String(repeating: "a", count: 64),
                candidateAppDigest: String(repeating: "9", count: 64),
                policy: IntentEvidenceChecker.policyID, mode: "app-change",
                referenceTime: Date(timeIntervalSince1970: 100)
            )
        }
    }

    @Test func trustedRoutePopulationRejectsOmittedSiriAttempts() throws {
        let fixture = try nativeBundle(observed: "packing-001", claimedOutcome: .passed,
                                       executedTestCount: 1, xctestExitCode: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var item = fixture.snapshot.cases[0]
        var definition = item.definition
        definition.coverage.siri = .required
        definition.coverage.siriAttemptCount = 3
        definition = try definition.frozen()
        item.definition = definition
        item.plan.definitionDigest = definition.definitionDigest
        item.plan.testContractDigest = try #require(definition.testContractDigest)
        item.runs[0].scenarioDigest = definition.definitionDigest
        item.runs[0].testContractDigest = definition.testContractDigest
        item.runs[0].invocation.scenarioDigest = definition.definitionDigest
        item.runs[0].negotiatedCapabilities = ScenarioHarnessCapabilities.required(for: definition).sorted()
        item.journals[0].invocation = item.runs[0].invocation
        item.record = try ScenarioExecutionRecord.make(
            plan: item.plan, records: item.record.records,
            completedAt: item.record.completedAt
        )
        let decision = IntentEvidenceQualification.qualify(
            item, requirement: .init(required: true, definition: definition),
            referenceTime: Date(timeIntervalSince1970: 100)
        )
        #expect(decision.incompleteEvidence.contains {
            $0.contains("planned route and attempt population differs from the trusted requirement")
        })
    }

    @Test func allOptionalCollectionAndNoncomparableResultCannotExitZero() throws {
        let fixture = try nativeBundle(observed: "packing-001", claimedOutcome: .passed,
                                       executedTestCount: 1, xctestExitCode: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.bundle)
        var snapshot = fixture.snapshot
        snapshot.requirements.cases[0].required = false
        try IntentEvidenceBundle.export(snapshot, to: fixture.bundle)
        try encode(snapshot.requirements).write(to: fixture.requirements, options: .atomic)
        let checked = try IntentEvidenceChecker.check(
            bundle: fixture.bundle, requirements: fixture.requirements,
            expectedSource: "revision-a", expectedAppDigest: String(repeating: "a", count: 64),
            policy: IntentEvidenceChecker.policyID,
            referenceTime: Date(timeIntervalSince1970: 100)
        )
        #expect(checked.exitCode == 20)
        let compared = try IntentEvidenceChecker.compare(
            baseline: fixture.bundle, candidate: fixture.bundle,
            requirements: fixture.requirements,
            baselineSource: "revision-a", candidateSource: "revision-a",
            baselineAppDigest: String(repeating: "a", count: 64),
            candidateAppDigest: String(repeating: "a", count: 64),
            policy: IntentEvidenceChecker.policyID, mode: "app-change",
            referenceTime: Date(timeIntervalSince1970: 100)
        )
        #expect(compared.exitCode == 20)
    }

    @Test func completedOptionalSiriChildIsBoundWithoutGatingRequiredOutcome() throws {
        let fixture = try nativeBundle(observed: "packing-001", claimedOutcome: .passed,
                                       executedTestCount: 1, xctestExitCode: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var item = fixture.snapshot.cases[0]
        var definition = item.definition
        definition.coverage.siri = .optional
        definition.coverage.siriAttemptCount = 1
        definition.checkMode = .behaviour
        definition.requiredClaims?.append(.applicationStateChecked)
        definition.observationPlan?.append(.init(
            id: "siriState", source: .testOnlyIntent,
            operationID: "readSiriState", selector: nil
        ))
        let siriAssertion = ScenarioAssertion(
            kind: .stateTransition, observationKey: "siriState",
            expectedValue: .string("open"), explanation: "Observe final app state.",
            applicableLanes: [.intentIntegration, .siri]
        )
        definition.assertions.append(siriAssertion)
        definition = try definition.frozen()
        item.definition = definition
        item.plan.definitionDigest = definition.definitionDigest
        item.plan.testContractDigest = try #require(definition.testContractDigest)
        item.runs[0].scenarioDigest = definition.definitionDigest
        item.runs[0].testContractDigest = definition.testContractDigest
        item.runs[0].invocation.scenarioDigest = definition.definitionDigest
        item.runs[0].negotiatedCapabilities = ScenarioHarnessCapabilities.required(for: definition).sorted()
        item.runs[0].laneResults[0].observations["siriState"] = .string("open")
        item.runs[0].laneResults[0].observationSources?["siriState"] = .testOnlyIntent
        item.runs[0].laneResults[0].assertionResults.append(.init(
            assertionID: siriAssertion.id, passed: true,
            observedValue: .string("open"), message: "Observed final state"
        ))
        item.runs[0].laneResults[0].claims?.append(.applicationStateChecked)
        item.journals[0].invocation = item.runs[0].invocation

        let optionalCoordinate = ScenarioPlannedCoordinate(
            id: UUID(), caseID: definition.id, lane: .siri,
            repetition: 1, required: false
        )
        item.plan.coordinates.append(optionalCoordinate)
        var siriRun = item.runs[0]
        siriRun.id = UUID()
        siriRun.invocation.id = siriRun.id
        siriRun.invocation.nonce = UUID().uuidString
        siriRun.invocation.resultBundleIdentity = UUID().uuidString
        var siriLane = siriRun.laneResults[0]
        siriLane.id = UUID()
        siriLane.lane = .siri
        siriLane.observations["siriState"] = .string("open")
        siriLane.observationSources?["siriState"] = .testOnlyIntent
        siriLane.assertionResults = [.init(
            assertionID: siriAssertion.id, passed: true,
            observedValue: .string("open"), message: "Observed final state"
        )]
        siriRun.laneResults = [siriLane]
        var siriJournal = item.journals[0]
        siriJournal.invocation = siriRun.invocation
        item.runs.append(siriRun)
        item.journals.append(siriJournal)
        var terminal = ScenarioExecutionCoordinateRecord(
            coordinate: optionalCoordinate, state: .completed,
            evidenceRunID: siriRun.id, evidenceLaneResultID: siriLane.id,
            detail: nil
        )
        terminal.laneResult = siriLane
        var nativeTerminal = item.record.records[0]
        nativeTerminal.laneResult = item.runs[0].laneResults[0]
        item.record = try ScenarioExecutionRecord.make(
            plan: item.plan, records: [nativeTerminal, terminal],
            completedAt: Date(timeIntervalSince1970: 100)
        )
        let requirement = IntentEvidenceRequirements.CaseRequirement(
            required: true, definition: definition
        )
        let passed = IntentEvidenceQualification.qualify(
            item, requirement: requirement, referenceTime: Date(timeIntervalSince1970: 100)
        )
        #expect(passed.incompleteEvidence.isEmpty)
        #expect(passed.requiredFailures.isEmpty)
        #expect(passed.report?.outcome == .passed)

        siriLane.outcome = .failed
        siriRun.laneResults = [siriLane]
        siriRun.outcome = .failed
        siriRun.xctestExitCode = 1
        terminal.laneResult = siriLane
        item.runs[1] = siriRun
        item.record = try ScenarioExecutionRecord.make(
            plan: item.plan, records: item.record.records.filter { $0.id != optionalCoordinate.id } + [terminal],
            completedAt: Date(timeIntervalSince1970: 100)
        )
        let failedOptional = IntentEvidenceQualification.qualify(
            item, requirement: requirement, referenceTime: Date(timeIntervalSince1970: 100)
        )
        #expect(!failedOptional.incompleteEvidence.isEmpty)
        #expect(failedOptional.requiredFailures.isEmpty)
        #expect(failedOptional.incompleteEvidence.contains {
            $0.contains("nonzero XCTest process exit")
        })
        #expect(failedOptional.report?.outcome == .incompleteOrIncompatibleEvidence)

        var recoveryItem = item
        recoveryItem.runs = [item.runs[0]]
        recoveryItem.journals = [item.journals[0]]
        var pendingOptional = ScenarioExecutionCoordinateRecord.unstarted(optionalCoordinate)
        pendingOptional.state = .recoveryRequired
        let requiredTerminal = try #require(item.record.records.first {
            $0.coordinate.required
        })
        recoveryItem.record = try ScenarioExecutionRecord.make(
            plan: item.plan, records: [requiredTerminal, pendingOptional],
            completedAt: Date(timeIntervalSince1970: 100)
        )
        let unresolvedRecovery = IntentEvidenceQualification.qualify(
            recoveryItem, requirement: requirement, referenceTime: Date(timeIntervalSince1970: 100)
        )
        #expect(unresolvedRecovery.incompleteEvidence.contains {
            $0.contains("remains in recovery")
        })
    }

    @Test func fullBatchFailedOptionalMemberMatchesCollectionVerdict() throws {
        let requiredFixture = try nativeBundle(
            observed: "packing-001", claimedOutcome: .passed,
            executedTestCount: 1, xctestExitCode: 0
        )
        let optionalFixture = try nativeBundle(
            observed: "wrong-note", claimedOutcome: .failed,
            executedTestCount: 1, xctestExitCode: 1
        )
        defer {
            try? FileManager.default.removeItem(at: requiredFixture.root)
            try? FileManager.default.removeItem(at: optionalFixture.root)
        }
        let first = requiredFixture.snapshot.cases[0]
        let second = optionalFixture.snapshot.cases[0]
        let collection = try ScenarioCollection(
            projectID: UUID(), name: "Required and optional notes",
            members: [try .init(definition: first.definition), try .init(definition: second.definition)]
        )
        var manifest = ScenarioCollectionBatchManifest(
            id: UUID(), collectionID: collection.id, collectionVersion: collection.version,
            membershipDigest: collection.membershipDigest,
            appProductDigest: first.plan.appProductDigest, scope: .full,
            priorBatchID: nil,
            cases: [
                .init(member: collection.members[0], executionPlanID: first.plan.id,
                      fixtureContractDigest: first.definition.fixture.digest,
                      targetBundleIdentifier: first.definition.target.bundleIdentifier,
                      featureID: nil, expectedSubjectInputDigest: nil),
                .init(member: collection.members[1], executionPlanID: second.plan.id,
                      fixtureContractDigest: second.definition.fixture.digest,
                      targetBundleIdentifier: second.definition.target.bundleIdentifier,
                      featureID: nil, expectedSubjectInputDigest: nil)
            ],
            coordinates: first.plan.coordinates + second.plan.coordinates,
            createdAt: Date(timeIntervalSince1970: 99), manifestDigest: ""
        )
        manifest.manifestDigest = try manifest.calculatedDigest()
        let result = ScenarioCollectionBatchResult(
            id: manifest.id, manifestID: manifest.id,
            executions: [first.record, second.record],
            recordedAt: Date(timeIntervalSince1970: 101)
        )
        let batchAssessment = ScenarioCollectionService.assess(
            manifest: manifest, collection: collection, result: result,
            runs: first.runs + second.runs
        )
        #expect(batchAssessment.qualification == .failedFull)
        let trusted = IntentEvidenceRequirements(
            collectionID: collection.id.uuidString,
            cases: [
                .init(required: true, definition: first.definition),
                .init(required: false, definition: second.definition)
            ]
        )
        let bundle = requiredFixture.root.appending(path: "failed-optional.intentlabrun")
        let requirementsURL = requiredFixture.root.appending(path: "failed-optional-requirements.json")
        try IntentEvidenceBundle.export(.init(
            requirements: trusted, cases: [first, second], sourceRevision: "revision-a",
            collection: collection, batchManifest: manifest, batchResult: result
        ), to: bundle)
        try encode(trusted).write(to: requirementsURL, options: .atomic)
        let checked = try IntentEvidenceChecker.check(
            bundle: bundle, requirements: requirementsURL,
            expectedSource: "revision-a", expectedAppDigest: String(repeating: "a", count: 64),
            policy: IntentEvidenceChecker.policyID,
            referenceTime: Date(timeIntervalSince1970: 101)
        )
        #expect(checked.exitCode == 20)
        #expect(String(decoding: checked.json, as: UTF8.self).contains(
            "nonzero XCTest process exit"
        ))
    }

    @Test func importedLocalFeatureBatchUsesItsAcceptedJournal() throws {
        let projectID = UUID()
        let fixture = try nativeBundle(
            observed: "packing-001", claimedOutcome: .passed,
            executedTestCount: 1, xctestExitCode: 0, projectID: projectID
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let native = fixture.snapshot.cases[0]

        var definition = ScenarioDefinition.starter(projectID: projectID)
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.name = "Local Feature summary"
        definition.coverage = .init(
            appFeature: .required, intentIntegration: .notApplicable,
            siri: .notApplicable, siriAttemptCount: 1
        )
        definition.fixture.digest = String(repeating: "c", count: 64)
        definition.integration = .init(
            id: "notes", version: "1", digest: String(repeating: "e", count: 64)
        )
        definition.featureBinding = .init(
            featureID: "summarize", interfaceDigest: String(repeating: "7", count: 64),
            inputMapping: [], outputProjections: []
        )
        definition.actionPolicyVersion = 1
        definition.actionRequirements = [.init(
            lane: .appFeature, kind: .productionService,
            operationID: "SummarizeService", resolvedParameters: [:]
        )]
        definition.assertions = [.init(
            kind: .returnedField, observationKey: "feature.response",
            expectedValue: .string("A summary"), explanation: "Return the requested summary.",
            applicableLanes: [.appFeature]
        )]
        definition.observationPlan = [.init(
            id: "feature.response", source: .testOnlyIntent,
            operationID: nil, selector: nil
        )]
        definition.purpose = .releaseRequirement
        definition.checkMode = .basic
        definition.requiredClaims = [.executionCompleted, .returnedValueChecked]
        definition = try definition.frozen()

        let now = Date(timeIntervalSince1970: 90)
        let appHash = native.plan.appProductDigest
        let testHash = native.plan.testProductDigest
        let collection = try ScenarioCollection(
            projectID: projectID, name: "Local Feature release checks",
            members: [try .init(definition: native.definition), try .init(definition: definition)]
        )
        let featureInput = try ScenarioFeatureSubjectDigest.digest(
            binding: try #require(definition.featureBinding), fixture: definition.fixture
        )
        let featureMember = try #require(collection.members.first { $0.caseID == definition.id })
        let featureCoordinate = ScenarioPlannedCoordinate(
            id: UUID(), caseID: definition.id, lane: .appFeature,
            repetition: 1, required: true
        )
        let profile = ScenarioExecutionProfile(
            id: UUID(), projectPath: "fixture", scheme: "Fixture",
            testTarget: "FixtureUITests", destinationIdentifier: "simulator",
            signingSelection: nil, trustedConnectionID: nil, buildConfiguration: nil,
            featureBackend: .projectLocalTestControl
        )
        let featurePlan = try ScenarioExecutionPlan.make(
            definition: definition, profile: profile,
            appProductDigest: appHash, testProductDigest: testHash,
            sourceInputsDigest: String(repeating: "d", count: 64),
            sourceRevision: "revision-a", runnerBuildID: nil, runnerID: nil,
            plannedCoordinates: [featureCoordinate], purpose: .fullRequirement,
            createdAt: now
        )
        var manifest = ScenarioCollectionBatchManifest(
            id: UUID(), collectionID: collection.id, collectionVersion: collection.version,
            membershipDigest: collection.membershipDigest, appProductDigest: appHash,
            scope: .full, priorBatchID: nil,
            cases: [
                .init(member: collection.members[0], executionPlanID: native.plan.id,
                      fixtureContractDigest: native.definition.fixture.digest,
                      targetBundleIdentifier: native.definition.target.bundleIdentifier,
                      featureID: nil, expectedSubjectInputDigest: nil),
                .init(member: featureMember, executionPlanID: featurePlan.id,
                      fixtureContractDigest: definition.fixture.digest,
                      targetBundleIdentifier: definition.target.bundleIdentifier,
                      featureID: definition.featureBinding?.featureID,
                      expectedSubjectInputDigest: featureInput)
            ],
            coordinates: native.plan.coordinates + [featureCoordinate],
            createdAt: now, manifestDigest: "",
            featureBackend: .projectLocalTestControl
        )
        manifest.manifestDigest = try manifest.calculatedDigest()

        let startedAt = now.addingTimeInterval(11)
        let completedAt = startedAt.addingTimeInterval(1)
        let capabilities = ScenarioHarnessCapabilities.required(
            for: definition, scope: .init(lane: .appFeature, attempt: 1),
            featureBackend: .projectLocalTestControl
        ).sorted()
        let invocation = ScenarioInvocationIdentity(
            id: UUID(), nonce: UUID().uuidString, issuedAt: startedAt,
            testIdentity: .init(bundleIdentifier: "com.example.FixtureUITests",
                                className: "IntentLabFixtureUITests", methodName: "testLocalFeature"),
            harnessVersion: ScenarioInvocationIdentity.reusableHarnessVersion,
            destinationIdentifier: "simulator", scenarioDigest: definition.definitionDigest,
            resultBundleIdentity: UUID().uuidString,
            appProduct: .init(bundleIdentifier: definition.target.bundleIdentifier,
                              executableName: "Fixture", sha256: appHash),
            testProduct: .init(bundleIdentifier: "com.example.FixtureUITests",
                               executableName: "FixtureUITests", sha256: testHash),
            integration: definition.integration, requiredCapabilities: capabilities,
            featureBackend: .projectLocalTestControl
        )
        let action = try #require(definition.actionRequirements?.first)
        let receipt = ScenarioActionReceipt(
            executionID: UUID(), appSessionID: UUID(),
            attemptContext: "feature-\(invocation.id.uuidString)",
            lane: .appFeature, attempt: 1, kind: action.kind,
            operationID: action.operationID, resolvedParameters: action.resolvedParameters,
            terminalStatus: .succeeded, operationError: nil, sequence: 1,
            startedAt: startedAt, completedAt: completedAt,
            observationTransport: .testOnlyIntent
        )
        let observations: [String: ScenarioValue] = [
            "feature.response": .string("A summary"),
            "intentlab.actionReceipts": .string(
                String(decoding: try encode([receipt]), as: UTF8.self)
            )
        ]
        let evaluated = ScenarioResultEvaluator.evaluate(
            definition: definition, lane: .appFeature, observations: observations,
            executionStatus: .completed, actionReceipts: [receipt],
            invocation: invocation, attempt: 1
        )
        let lane = ScenarioLaneResult(
            caseID: definition.id, attempt: 1, lane: .appFeature,
            executionStatus: .completed, outcome: evaluated.0,
            startedAt: startedAt, completedAt: completedAt,
            observations: observations, assertionResults: evaluated.1,
            observationSources: ["feature.response": .testOnlyIntent,
                                 "intentlab.actionReceipts": .testOnlyIntent],
            actionReceipts: [receipt], cleanupVerified: true
        )
        var run = ScenarioRun(
            id: invocation.id, scenarioID: definition.id, scenarioVersion: definition.version,
            scenarioDigest: definition.definitionDigest, invocation: invocation,
            startedAt: startedAt, completedAt: completedAt,
            environment: .init(
                xcodeVersion: "27", sdkVersion: "27", deviceModel: "iPhone",
                operatingSystem: "iOS 27", operatingSystemBuild: "27A1",
                languageCode: "en", regionCode: "GB", timeZoneIdentifier: "UTC",
                siriConfiguration: nil, siriConfigurationSource: nil, executedAt: startedAt
            ),
            executionStatus: .completed, outcome: evaluated.0,
            laneResults: [lane], linkedFeatureRunID: nil, importedAt: completedAt
        )
        run.xctestExitCode = 0
        run.fixture = definition.fixture
        run.integration = definition.integration
        run.runnerPackageVersion = "fixture-package-1"
        run.negotiatedCapabilities = capabilities
        run.acceptanceStatus = .accepted
        run.scenarioSchemaVersion = ScenarioDefinition.stableSchemaVersion
        run.testContractDigest = definition.testContractDigest
        run.measurementImplementation = .init(
            observerID: "observer", observerDigest: testHash,
            evaluatorID: "evaluator", evaluatorDigest: testHash
        )
        run.comparisonEnvironmentIdentity = .init(
            profileID: "simulator-en", profileDigest: String(repeating: "f", count: 64)
        )
        run.executedTestCount = 1
        let journal = ScenarioExecutionJournal(
            phase: .stopped, invocation: invocation,
            scenarioID: definition.id, scenarioVersion: definition.version,
            resultBundlePath: "result.xcresult", derivedDataPath: "DerivedData",
            buildLogPath: "build.log", intendedExecutable: "xcodebuild",
            intendedArguments: [], processIdentifier: nil, processStartedAt: startedAt,
            updatedAt: completedAt, recoveryReason: nil, evidenceAccepted: true,
            scope: .init(lane: .appFeature, attempt: 1)
        )
        var terminal = ScenarioExecutionCoordinateRecord(
            coordinate: featureCoordinate, state: .completed,
            evidenceRunID: run.id, evidenceLaneResultID: lane.id, detail: nil
        )
        terminal.laneResult = lane
        let featureRecord = try ScenarioExecutionRecord.make(
            plan: featurePlan, records: [terminal], completedAt: completedAt
        )
        let trusted = IntentEvidenceRequirements(
            collectionID: collection.id.uuidString,
            cases: [.init(required: true, definition: native.definition),
                    .init(required: false, definition: definition)]
        )
        var snapshot = IntentEvidenceBundleSnapshot(
            requirements: trusted,
            cases: [native, .init(definition: definition, plan: featurePlan,
                                  record: featureRecord, runs: [run], journals: [journal])],
            sourceRevision: "revision-a"
        )
        snapshot.collection = collection
        snapshot.batchManifest = manifest
        snapshot.batchResult = .init(
            id: manifest.id, manifestID: manifest.id,
            executions: [native.record, featureRecord], recordedAt: completedAt
        )
        try FileManager.default.removeItem(at: fixture.bundle)
        try IntentEvidenceBundle.export(snapshot, to: fixture.bundle)
        try encode(trusted).write(to: fixture.requirements, options: .atomic)
        let checked = try IntentEvidenceChecker.check(
            bundle: fixture.bundle, requirements: fixture.requirements,
            expectedSource: "revision-a", expectedAppDigest: appHash,
            policy: IntentEvidenceChecker.policyID,
            referenceTime: Date(timeIntervalSince1970: 120)
        )
        #expect(checked.exitCode == 0)
    }

    @Test func partialBaselineCannotQualifyFullCollectionComparison() throws {
        let fixture = try nativeBundle(observed: "packing-001", claimedOutcome: .passed,
                                       executedTestCount: 1, xctestExitCode: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let item = fixture.snapshot.cases[0]
        let collection = try ScenarioCollection(
            projectID: UUID(), name: "Single note check",
            members: [try .init(definition: item.definition)]
        )
        var trusted = fixture.trusted
        trusted.collectionID = collection.id.uuidString
        let now = Date(timeIntervalSince1970: 100)
        var batch = ScenarioCollectionBatchManifest(
            id: UUID(), collectionID: collection.id, collectionVersion: collection.version,
            membershipDigest: collection.membershipDigest,
            appProductDigest: item.plan.appProductDigest, scope: .selected,
            priorBatchID: nil,
            cases: [.init(member: collection.members[0], executionPlanID: item.plan.id,
                          fixtureContractDigest: item.definition.fixture.digest,
                          targetBundleIdentifier: item.definition.target.bundleIdentifier,
                          featureID: nil, expectedSubjectInputDigest: nil)],
            coordinates: item.plan.coordinates, createdAt: now, manifestDigest: ""
        )
        batch.manifestDigest = try batch.calculatedDigest()
        let result = ScenarioCollectionBatchResult(
            id: batch.id, manifestID: batch.id,
            executions: [item.record], recordedAt: now
        )
        var baseline = fixture.snapshot
        baseline.requirements = trusted
        baseline.collection = collection
        baseline.batchManifest = batch
        baseline.batchResult = result
        let baselineURL = fixture.root.appending(path: "selected-baseline.intentlabrun")
        let candidateURL = fixture.root.appending(path: "full-candidate.intentlabrun")
        try IntentEvidenceBundle.export(baseline, to: baselineURL)
        var candidate = fixture.snapshot
        candidate.requirements = trusted
        try IntentEvidenceBundle.export(candidate, to: candidateURL)
        try encode(trusted).write(to: fixture.requirements, options: .atomic)
        let comparison = try IntentEvidenceChecker.compare(
            baseline: baselineURL, candidate: candidateURL,
            requirements: fixture.requirements,
            baselineSource: "revision-a", candidateSource: "revision-a",
            baselineAppDigest: String(repeating: "a", count: 64),
            candidateAppDigest: String(repeating: "a", count: 64),
            policy: IntentEvidenceChecker.policyID, mode: "app-change",
            referenceTime: now
        )
        #expect(String(decoding: comparison.json, as: UTF8.self).contains(
            "Baseline: Partial batch scope cannot qualify the full collection"
        ))
    }

    @Test func featureRawOutputAndTrustedInputCannotBeReplacedByResealedObservations() throws {
        let fixture = try nativeBundle(observed: "packing-001", claimedOutcome: .passed,
                                       executedTestCount: 1, xctestExitCode: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var item = fixture.snapshot.cases[0]
        var definition = item.definition
        definition.coverage.appFeature = .required
        let field = ScenarioOutputField(
            name: "featureSelectedNoteID", type: .primitive(.string),
            path: [.init(kind: .property, name: "selectedNoteID")]
        )
        definition.featureBinding = .init(
            featureID: "summarize", interfaceDigest: String(repeating: "7", count: 64),
            inputMapping: [.init(featureInputName: "noteID", value: .string("packing-001"))],
            outputProjections: [field]
        )
        definition.directControl.outputFields.append(field)
        definition.observationPlan?.append(.init(
            id: field.name, source: .intentResult, operationID: nil, selector: nil
        ))
        let featureAssertion = ScenarioAssertion(
            kind: .returnedField, observationKey: field.name,
            expectedValue: .string("packing-001"), explanation: "Use the selected note.",
            applicableLanes: [.appFeature]
        )
        definition.assertions.append(featureAssertion)
        definition = try definition.frozen()
        item.definition = definition
        item.plan.definitionDigest = definition.definitionDigest
        item.plan.testContractDigest = try #require(definition.testContractDigest)
        item.plan.runnerBuildID = item.plan.appProductDigest
        item.plan.runnerID = UUID()
        item.runs[0].scenarioDigest = definition.definitionDigest
        item.runs[0].testContractDigest = definition.testContractDigest
        item.runs[0].invocation.scenarioDigest = definition.definitionDigest
        item.runs[0].negotiatedCapabilities = ScenarioHarnessCapabilities.required(for: definition).sorted()
        item.journals[0].invocation = item.runs[0].invocation

        let coordinate = ScenarioPlannedCoordinate(
            id: UUID(), caseID: definition.id, lane: .appFeature,
            repetition: 1, required: true
        )
        item.plan.coordinates.append(coordinate)
        let featureRunID = UUID()
        let sampleID = UUID()
        let now = Date(timeIntervalSince1970: 100)
        let correctInputDigest = try ScenarioFeatureSubjectDigest.digest(
            binding: try #require(definition.featureBinding), fixture: definition.fixture
        )
        let metadata = [
            "intentlab.attemptID": coordinate.id.uuidString,
            "intentlab.caseID": definition.id.uuidString,
            "intentlab.subjectInputDigest": correctInputDigest,
            "intentlab.fixtureDigest": definition.fixture.digest
        ]
        let featureLane = ScenarioLaneResult(
            caseID: definition.id, attempt: 1, lane: .appFeature,
            executionStatus: .completed, outcome: .passed,
            startedAt: now, completedAt: now,
            observations: [
                "feature.response": .string("summary"),
                "feature.runID": .string(featureRunID.uuidString),
                "feature.sampleID": .string(sampleID.uuidString),
                "feature.resultCount": .integer(1),
                "featureSelectedNoteID": .string("packing-001"),
                "feature.metadata.intentlab.attemptID": .string(coordinate.id.uuidString),
                "feature.metadata.intentlab.caseID": .string(definition.id.uuidString),
                "feature.metadata.intentlab.subjectInputDigest": .string(correctInputDigest),
                "feature.metadata.intentlab.fixtureDigest": .string(definition.fixture.digest)
            ],
            assertionResults: [.init(
                assertionID: featureAssertion.id, passed: true,
                observedValue: .string("packing-001"), message: "Producer result"
            )],
            observationSources: [field.name: .appIntentsTesting]
        )
        var child = try ScenarioFeatureChildEvidence(
            runID: featureRunID, sampleID: sampleID, startedAt: now, completedAt: now,
            caseID: definition.id, attempt: 1, response: "summary",
            encodedOutput: Data(#"{"selectedNoteID":"wrong-note"}"#.utf8),
            encodedOutputTypeName: "NoteOutput", outputMetadata: metadata,
            errorCategory: nil, errorMessage: nil,
            appBundleIdentifier: definition.target.bundleIdentifier,
            featureID: "summarize", featureVersion: "1",
            checkedAppProductDigest: item.plan.appProductDigest,
            runnerBuildID: item.plan.appProductDigest,
            fixtureContractDigest: item.plan.fixtureContractDigest,
            subjectInputDigest: correctInputDigest, digest: "",
            measurementImplementation: .init(
                observerID: "feature-observer", observerDigest: String(repeating: "8", count: 64),
                evaluatorID: "host-evaluator", evaluatorDigest: String(repeating: "9", count: 64)
            )
        ).sealed()
        var featureTerminal = ScenarioExecutionCoordinateRecord(
            coordinate: coordinate, state: .completed,
            evidenceRunID: featureRunID, evidenceLaneResultID: featureLane.id, detail: nil
        )
        featureTerminal.laneResult = featureLane
        featureTerminal.featureChild = child
        featureTerminal.evidenceDigest = child.digest
        item.record = try ScenarioExecutionRecord.make(
            plan: item.plan, records: item.record.records + [featureTerminal],
            completedAt: now
        )
        let requirement = IntentEvidenceRequirements.CaseRequirement(
            required: true, definition: definition
        )
        let alteredOutput = IntentEvidenceQualification.qualify(
            item, requirement: requirement, referenceTime: now
        )
        #expect(alteredOutput.incompleteEvidence.contains {
            $0.contains("App Feature observations do not match the retained raw child output")
        })

        child.encodedOutput = Data(#"{"selectedNoteID":"packing-001"}"#.utf8)
        child.outputMetadata["intentlab.subjectInputDigest"] = String(repeating: "0", count: 64)
        child.subjectInputDigest = String(repeating: "0", count: 64)
        child = try child.sealed()
        featureTerminal.featureChild = child
        featureTerminal.evidenceDigest = child.digest
        item.record = try ScenarioExecutionRecord.make(
            plan: item.plan, records: item.record.records.filter { $0.id != coordinate.id } + [featureTerminal],
            completedAt: now
        )
        let alteredInput = IntentEvidenceQualification.qualify(
            item, requirement: requirement, referenceTime: now
        )
        #expect(alteredInput.incompleteEvidence.contains {
            $0.contains("App Feature input digest differs from the trusted binding and fixture")
        })

        child.subjectInputDigest = correctInputDigest
        child.outputMetadata["intentlab.subjectInputDigest"] = correctInputDigest
        child.outputMetadata["intentlab.fixtureDigest"] = String(repeating: "f", count: 64)
        child = try child.sealed()
        featureTerminal.featureChild = child
        featureTerminal.evidenceDigest = child.digest
        var wrongSourceLane = featureLane
        wrongSourceLane.observations["feature.metadata.intentlab.fixtureDigest"] =
            .string(String(repeating: "f", count: 64))
        featureTerminal.laneResult = wrongSourceLane
        item.record = try ScenarioExecutionRecord.make(
            plan: item.plan, records: item.record.records.filter { $0.id != coordinate.id } + [featureTerminal],
            completedAt: now
        )
        let wrongSource = IntentEvidenceQualification.qualify(
            item, requirement: requirement, referenceTime: now
        )
        #expect(wrongSource.requiredFailures.contains {
            $0.contains("used different source content than the trusted fixture")
        })
    }

    @Test func semanticRequirementNeedsAnExternalPolicyPin() throws {
        let fixture = try fixtureBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var trusted = fixture.trusted
        trusted.cases[0].definition.assertions.append(.init(
            kind: .semanticRubric, observationKey: "selectedNoteID",
            expectedValue: .string("packing-001"), explanation: "Preserve the source.",
            applicableLanes: [.intentIntegration]
        ))
        trusted.cases[0].definition = try trusted.cases[0].definition.frozen()
        try encode(trusted).write(to: fixture.requirements, options: .atomic)
        #expect(throws: Error.self) {
            try IntentEvidenceBundle.decodeRequirements(fixture.requirements)
        }
    }

    @Test func acceptedWrongActionRemainsVisibleWhileCleanupIsUnresolved() throws {
        let fixture = try nativeBundle(
            observed: "packing-001", claimedOutcome: .failed,
            executedTestCount: 1, xctestExitCode: 0
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var item = fixture.snapshot.cases[0]
        var definition = item.definition
        definition.actionPolicyVersion = 1
        definition.actionRequirements = [.init(
            lane: .intentIntegration, kind: .productionIntent,
            operationID: "OpenNoteIntent", resolvedParameters: [:]
        )]
        definition = try definition.frozen()
        item.definition = definition
        item.plan.definitionDigest = definition.definitionDigest
        item.plan.testContractDigest = try #require(definition.testContractDigest)
        var run = item.runs[0]
        run.scenarioDigest = definition.definitionDigest
        run.testContractDigest = definition.testContractDigest
        run.invocation.scenarioDigest = definition.definitionDigest
        run.negotiatedCapabilities = ScenarioHarnessCapabilities.required(for: definition).sorted()
        let now = Date(timeIntervalSince1970: 100)
        let receipt = ScenarioActionReceipt(
            executionID: UUID(), appSessionID: UUID(),
            attemptContext: "intent-\(run.invocation.id.uuidString)",
            lane: .intentIntegration, attempt: 1, kind: .productionIntent,
            operationID: "SummarizeNoteIntent", resolvedParameters: [:],
            terminalStatus: .succeeded, operationError: nil, sequence: 1,
            startedAt: now, completedAt: now,
            observationTransport: .accessibleUI
        )
        var lane = run.laneResults[0]
        lane.actionReceipts = [receipt]
        lane.actionFailureReason = .wrongAction
        lane.cleanupVerified = false
        lane.observations["intentlab.actionReceipts"] = .string(
            String(decoding: try encode([receipt]), as: UTF8.self)
        )
        lane.observationSources?["intentlab.actionReceipts"] = .accessibleUI
        run.laneResults = [lane]
        item.runs = [run]
        item.journals[0].invocation = run.invocation
        item.journals[0].phase = .recoveryRequired
        var terminal = item.record.records[0]
        terminal.laneResult = lane
        item.record = try ScenarioExecutionRecord.make(
            plan: item.plan, records: [terminal], completedAt: now
        )
        let decision = IntentEvidenceQualification.qualify(
            item, requirement: .init(required: true, definition: definition),
            referenceTime: now
        )
        #expect(decision.incompleteEvidence.contains { $0.contains("cleanup or device readiness") })
        #expect(decision.requiredFailures.contains { $0.contains("wrongAction") })
        #expect(decision.report?.outcome == .incompleteOrIncompatibleEvidence)
    }

    @Test func fullyPassingDiagnosticPlanAndHistoricalGreenRowCannotQualify() throws {
        let fixture = try nativeBundle(
            observed: "packing-001", claimedOutcome: .passed,
            executedTestCount: 1, xctestExitCode: 0
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var item = fixture.snapshot.cases[0]
        item.plan.purpose = .partialDiagnostic

        // This passing historical result is outside the saved diagnostic
        // population. Qualification must not use it to fill omitted routes.
        var oldRun = try #require(item.runs.first)
        oldRun.invocation.id = UUID()
        oldRun.id = oldRun.invocation.id
        var oldLane = try #require(oldRun.laneResults.first)
        oldLane.id = UUID()
        oldLane.lane = .siri
        oldLane.attempt = 1
        oldRun.laneResults = [oldLane]
        oldRun.outcome = .passed
        var oldJournal = try #require(item.journals.first)
        oldJournal.invocation = oldRun.invocation
        oldJournal.scope = .init(lane: .siri, attempt: 1)
        item.runs.append(oldRun)
        item.journals.append(oldJournal)

        let decision = IntentEvidenceQualification.qualify(
            item, requirement: .init(required: true, definition: item.definition),
            referenceTime: Date(timeIntervalSince1970: 100)
        )
        #expect(decision.report?.outcome == .incompleteOrIncompatibleEvidence)
        #expect(decision.incompleteEvidence.contains {
            $0.contains("Partial diagnostic execution")
        })
        #expect(decision.incompleteEvidence.contains {
            $0.contains("unreferenced evidence")
        })

        var diagnosticSnapshot = fixture.snapshot
        diagnosticSnapshot.cases[0] = item
        try FileManager.default.removeItem(at: fixture.bundle)
        try IntentEvidenceBundle.export(diagnosticSnapshot, to: fixture.bundle)
        let offline = try IntentEvidenceChecker.check(
            bundle: fixture.bundle, requirements: fixture.requirements,
            expectedSource: "revision-a", expectedAppDigest: String(repeating: "a", count: 64),
            policy: IntentEvidenceChecker.policyID,
            referenceTime: Date(timeIntervalSince1970: 100)
        )
        #expect(offline.exitCode == 20)
        #expect(String(decoding: offline.json, as: UTF8.self).contains("Partial diagnostic execution"))

        let completePopulationDiagnostic = fixture.snapshot.cases[0]
        var diagnosticPlan = completePopulationDiagnostic.plan
        diagnosticPlan.purpose = .partialDiagnostic
        let policy = ScenarioComparisonPolicy(
            mode: .compareAppChanges, baselineRunID: diagnosticPlan.id
        )
        var candidatePlan = diagnosticPlan
        candidatePlan.comparisonPolicy = policy
        let comparison = ScenarioExecutionComparison.compare(
            baseline: .init(plan: diagnosticPlan, record: completePopulationDiagnostic.record,
                            runs: completePopulationDiagnostic.runs,
                            definition: completePopulationDiagnostic.definition),
            candidate: .init(plan: candidatePlan, record: completePopulationDiagnostic.record,
                             runs: completePopulationDiagnostic.runs,
                             definition: completePopulationDiagnostic.definition),
            policy: policy
        )
        #expect(comparison.qualificationIssues?.contains {
            $0.contains("Partial diagnostic executions")
        } == true)
    }

    @Test func tamperingExtraFilesAndSymlinksAreRejected() throws {
        let fixture = try fixtureBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let definition = fixture.bundle.appending(path: "requirements/\(fixture.trusted.cases[0].definition.id.uuidString).json")
        try Data("changed".utf8).write(to: definition, options: .atomic)
        #expect(throws: Error.self) { try IntentEvidenceBundle.read(fixture.bundle) }

        // Restore the immutable bundle for independent filesystem checks.
        try FileManager.default.removeItem(at: fixture.bundle)
        try IntentEvidenceBundle.export(fixture.snapshot, to: fixture.bundle)
        try Data("extra".utf8).write(to: fixture.bundle.appending(path: "unlisted.txt"))
        #expect(throws: Error.self) { try IntentEvidenceBundle.read(fixture.bundle) }

        try FileManager.default.removeItem(at: fixture.bundle.appending(path: "unlisted.txt"))
        try FileManager.default.createSymbolicLink(
            at: fixture.bundle.appending(path: "linked.txt"), withDestinationURL: fixture.requirements
        )
        #expect(throws: Error.self) { try IntentEvidenceBundle.read(fixture.bundle) }
    }

    @Test func manifestTraversalAndSchemaMismatchAreRejected() throws {
        let fixture = try fixtureBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manifestURL = fixture.bundle.appending(path: "manifest.json")
        var manifest = try JSONDecoder().decode(IntentEvidenceBundleManifest.self, from: Data(contentsOf: manifestURL))
        manifest.files[0].path = "../outside.json"
        try encode(manifest).write(to: manifestURL, options: .atomic)
        #expect(throws: Error.self) { try IntentEvidenceBundle.read(fixture.bundle) }

        try FileManager.default.removeItem(at: fixture.bundle)
        try IntentEvidenceBundle.export(fixture.snapshot, to: fixture.bundle)
        manifest = try JSONDecoder().decode(IntentEvidenceBundleManifest.self, from: Data(contentsOf: manifestURL))
        manifest.schemaVersion = 99
        try encode(manifest).write(to: manifestURL, options: .atomic)
        #expect(throws: Error.self) { try IntentEvidenceBundle.read(fixture.bundle) }
    }

    @Test func declaredOversizedFileFailsBeforeItIsRead() throws {
        let fixture = try fixtureBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manifestURL = fixture.bundle.appending(path: "manifest.json")
        var manifest = try JSONDecoder().decode(
            IntentEvidenceBundleManifest.self, from: Data(contentsOf: manifestURL)
        )
        manifest.files[0].bytes = IntentEvidenceBundle.maximumFileBytes + 1
        try encode(manifest).write(to: manifestURL, options: .atomic)
        #expect(throws: Error.self) { try IntentEvidenceBundle.read(fixture.bundle) }
    }

    private struct Fixture {
        var root: URL
        var bundle: URL
        var requirements: URL
        var trusted: IntentEvidenceRequirements
        var snapshot: IntentEvidenceBundleSnapshot
    }

    private func fixtureBundle() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "evidence-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var definition = ScenarioDefinition.starter()
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.directControl.linkedFeatureRunID = nil
        definition.directControl.linkedFeatureSubjectDigest = ""
        definition = try definition.frozen()
        let coordinate = ScenarioPlannedCoordinate(
            id: UUID(), caseID: definition.id, lane: .intentIntegration,
            repetition: 1, required: true
        )
        var plan = ScenarioExecutionPlan(
            id: UUID(), definitionID: definition.id, definitionVersion: definition.version,
            definitionDigest: definition.definitionDigest,
            testContractDigest: try #require(definition.testContractDigest),
            profile: .init(id: UUID(), projectPath: "fixture", scheme: "Fixture",
                           testTarget: "FixtureUITests", destinationIdentifier: "simulator",
                           signingSelection: nil, trustedConnectionID: nil,
                           buildConfiguration: nil),
            appProductDigest: String(repeating: "a", count: 64),
            testProductDigest: String(repeating: "b", count: 64),
            fixtureContractDigest: definition.fixture.digest,
            coordinates: [coordinate], comparisonPolicy: nil, createdAt: Date(timeIntervalSince1970: 1)
        )
        plan.sourceRevision = "revision-a"
        let record = try ScenarioExecutionRecord.make(
            plan: plan,
            records: [.init(coordinate: coordinate, state: .notRun,
                            evidenceRunID: nil, evidenceLaneResultID: nil, detail: nil)],
            completedAt: Date(timeIntervalSince1970: 2)
        )
        let trusted = IntentEvidenceRequirements(
            collectionID: "sample-collection",
            cases: [.init(required: true, definition: definition)]
        )
        let snapshot = IntentEvidenceBundleSnapshot(
            requirements: trusted, cases: [.init(definition: definition, plan: plan,
                                                 record: record, runs: [], journals: [])],
            sourceRevision: "revision-a"
        )
        let bundle = root.appending(path: "sample.intentlabrun")
        let requirements = root.appending(path: "trusted.json")
        try IntentEvidenceBundle.export(snapshot, to: bundle)
        try encode(trusted).write(to: requirements)
        return .init(root: root, bundle: bundle, requirements: requirements,
                     trusted: trusted, snapshot: snapshot)
    }

    private func nativeBundle(
        observed: String, claimedOutcome: ScenarioOutcome,
        executedTestCount: Int, xctestExitCode: Int32, projectID: UUID? = nil,
        actionFailureReason: ScenarioActionFailureReason? = nil,
        purpose: ScenarioPurpose = .releaseRequirement
    ) throws -> Fixture {
        let now = Date(timeIntervalSince1970: 100)
        let root = FileManager.default.temporaryDirectory.appending(path: "native-evidence-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var definition = ScenarioDefinition.starter(projectID: projectID)
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.coverage.appFeature = .notApplicable
        definition.coverage.siri = .notApplicable
        definition.purpose = purpose
        definition.checkMode = .basic
        definition.requiredClaims = [.executionCompleted, .returnedValueChecked]
        definition.integration = .init(id: "notes", version: "1", digest: String(repeating: "e", count: 64))
        definition.fixture.digest = String(repeating: "c", count: 64)
        definition.directControl.outputFields[0].path = [.init(kind: .property, name: "selectedNoteID")]
        definition.observationPlan = [.init(id: "selectedNoteID", source: .intentResult,
                                            operationID: nil, selector: nil)]
        definition.assertions = [.init(
            kind: .returnedField, observationKey: "selectedNoteID",
            expectedValue: .string("packing-001"), explanation: "Open the requested note.",
            applicableLanes: [.intentIntegration]
        )]
        definition = try definition.frozen()
        let assertion = definition.assertions[0]
        let lane = ScenarioLaneResult(
            caseID: definition.id, attempt: 1, lane: .intentIntegration,
            executionStatus: .completed, outcome: claimedOutcome,
            startedAt: now, completedAt: now,
            observations: ["selectedNoteID": .string(observed)],
            assertionResults: [.init(assertionID: assertion.id, passed: claimedOutcome == .passed,
                                     observedValue: .string(observed), message: "Producer result")],
            observationSources: ["selectedNoteID": .appIntentsTesting],
            claims: [.executionCompleted, .returnedValueChecked],
            actionFailureReason: actionFailureReason
        )
        let appHash = String(repeating: "a", count: 64)
        let testHash = String(repeating: "b", count: 64)
        let coordinate = ScenarioPlannedCoordinate(
            id: UUID(), caseID: definition.id, lane: .intentIntegration,
            repetition: 1, required: true
        )
        var plan = ScenarioExecutionPlan(
            id: UUID(), definitionID: definition.id, definitionVersion: definition.version,
            definitionDigest: definition.definitionDigest,
            testContractDigest: try #require(definition.testContractDigest),
            profile: .init(id: UUID(), projectPath: "fixture", scheme: "Fixture",
                           testTarget: "FixtureUITests", destinationIdentifier: "simulator",
                           signingSelection: nil, trustedConnectionID: nil,
                           buildConfiguration: nil),
            appProductDigest: appHash, testProductDigest: testHash,
            fixtureContractDigest: definition.fixture.digest,
            coordinates: [coordinate], comparisonPolicy: nil, createdAt: now
        )
        plan.sourceInputsDigest = String(repeating: "d", count: 64)
        plan.sourceRevision = "revision-a"
        let invocation = ScenarioInvocationIdentity(
            id: UUID(), nonce: UUID().uuidString, issuedAt: now,
            testIdentity: .init(bundleIdentifier: "com.example.FixtureUITests",
                                className: "IntentLabFixtureUITests",
                                methodName: "testIntentLabScenario"),
            harnessVersion: ScenarioInvocationIdentity.reusableHarnessVersion,
            destinationIdentifier: "simulator", scenarioDigest: definition.definitionDigest,
            resultBundleIdentity: UUID().uuidString,
            appProduct: .init(bundleIdentifier: definition.target.bundleIdentifier,
                              executableName: "Fixture", sha256: appHash),
            testProduct: .init(bundleIdentifier: "com.example.FixtureUITests",
                               executableName: "FixtureUITests", sha256: testHash),
            integration: definition.integration, requiredCapabilities: []
        )
        var run = ScenarioRun(
            id: invocation.id, scenarioID: definition.id, scenarioVersion: definition.version,
            scenarioDigest: definition.definitionDigest, invocation: invocation,
            startedAt: now, completedAt: now,
            environment: .init(xcodeVersion: "27", sdkVersion: "27", deviceModel: "iPhone",
                               operatingSystem: "iOS 27", operatingSystemBuild: "27A1",
                               languageCode: "en", regionCode: "GB", timeZoneIdentifier: "UTC",
                               siriConfiguration: nil, siriConfigurationSource: nil, executedAt: now),
            executionStatus: .completed, outcome: claimedOutcome,
            laneResults: [lane], linkedFeatureRunID: nil, importedAt: now
        )
        run.scenarioSchemaVersion = ScenarioDefinition.stableSchemaVersion
        run.testContractDigest = definition.testContractDigest
        run.measurementImplementation = .init(
            observerID: "observer", observerDigest: testHash,
            evaluatorID: "evaluator", evaluatorDigest: testHash
        )
        run.comparisonEnvironmentIdentity = .init(
            profileID: "simulator-en", profileDigest: String(repeating: "f", count: 64)
        )
        run.fixture = definition.fixture
        run.integration = definition.integration
        run.runnerPackageVersion = "fixture-package-1"
        run.negotiatedCapabilities = ScenarioHarnessCapabilities.required(for: definition).sorted()
        run.xctestExitCode = xctestExitCode
        run.executedTestCount = executedTestCount
        var terminal = ScenarioExecutionCoordinateRecord(
            coordinate: coordinate, state: .completed, evidenceRunID: run.id,
            evidenceLaneResultID: lane.id, detail: nil
        )
        terminal.laneResult = lane
        let record = try ScenarioExecutionRecord.make(plan: plan, records: [terminal], completedAt: now)
        let journal = ScenarioExecutionJournal(
            phase: .stopped, invocation: invocation, scenarioID: definition.id,
            scenarioVersion: definition.version, resultBundlePath: "result.xcresult",
            derivedDataPath: "DerivedData", buildLogPath: "build.log",
            intendedExecutable: "xcodebuild", intendedArguments: [],
            processIdentifier: nil, processStartedAt: now, updatedAt: now,
            recoveryReason: nil, evidenceAccepted: xctestExitCode == 0
        )
        let trusted = IntentEvidenceRequirements(
            collectionID: "native-regressions",
            cases: [.init(required: true, definition: definition)]
        )
        let snapshot = IntentEvidenceBundleSnapshot(
            requirements: trusted,
            cases: [.init(definition: definition, plan: plan, record: record,
                          runs: [run], journals: [journal])],
            sourceRevision: "revision-a"
        )
        let bundle = root.appending(path: "native.intentlabrun")
        let requirements = root.appending(path: "trusted.json")
        try IntentEvidenceBundle.export(snapshot, to: bundle)
        try encode(trusted).write(to: requirements)
        return .init(root: root, bundle: bundle, requirements: requirements,
                     trusted: trusted, snapshot: snapshot)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
