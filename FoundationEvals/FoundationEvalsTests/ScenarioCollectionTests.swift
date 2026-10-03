import Foundation
import Testing
@testable import FoundationEvals

struct ScenarioCollectionTests {
    @Test func sameMemberIDsWithNewRevisionsEnableCollectionUpdate() throws {
        let original = try caseDefinition(projectID: UUID(), name: "Original")
        let collection = try ScenarioCollection(projectID: original.projectID!, name: "Collection", members: [ScenarioCollectionService.member(original)])
        #expect(ScenarioCollectionService.membershipMatchesLatest(collection, selectedIDs: [original.id], definitions: [original]))
        var updated = original
        updated.version += 1
        updated.goal.requestText += " revised"
        updated = try updated.frozen()
        #expect(!ScenarioCollectionService.membershipMatchesLatest(collection, selectedIDs: [original.id], definitions: [original, updated]))
    }

    @Test func omittedSiriAttemptCountUsesThreeAttemptsInBatch() throws {
        var definition = try caseDefinition(projectID: UUID(), name: "Siri default")
        definition.coverage = .init(appFeature: .notApplicable, intentIntegration: .notApplicable, siri: .required)
        definition.safety.mutationPolicy = .readOnly
        definition = try definition.frozen()
        let collection = try ScenarioCollection(projectID: definition.projectID!, name: "Siri", members: [ScenarioCollectionService.member(definition)])
        let manifest = try ScenarioCollectionService.freezeManifest(collection: collection, definitions: [definition], scope: .full, appProductDigest: "app")
        #expect(manifest.coordinates.map(\.repetition) == [1, 2, 3])
    }

    @Test func interruptedBatchKeepsEntirePlannedPopulationVisibleAfterRelaunch() async throws {
        let projectID = UUID()
        let definitions = try (0..<3).map { try caseDefinition(projectID: projectID, name: "Case \($0)") }
        let collection = try ScenarioCollection(
            projectID: projectID, name: "Summaries",
            members: try definitions.map(ScenarioCollectionService.member)
        )
        let instant = Date(timeIntervalSince1970: 1_800_000_000.234)
        let manifest = try ScenarioCollectionService.freezeManifest(
            collection: collection, definitions: definitions, scope: .full,
            appProductDigest: "app-build", createdAt: instant
        )
        #expect(manifest.coordinates.count == 3)
        let first = manifest.coordinates[0]
        let second = manifest.coordinates[1]
        let passing = run(for: definitions[0], coordinate: first, startedAt: instant.addingTimeInterval(1), outcome: .passed)
        let result = ScenarioCollectionBatchResult(
            id: manifest.id, manifestID: manifest.id,
            executions: [
                try execution(manifest: manifest, caseID: first.caseID, records: [
                    .init(coordinate: first, state: .completed, evidenceRunID: passing.id,
                          evidenceLaneResultID: passing.laneResults[0].id, detail: nil)
                ]),
                try execution(manifest: manifest, caseID: second.caseID, records: [
                    .init(coordinate: second, state: .cancelled, evidenceRunID: nil,
                          evidenceLaneResultID: nil, detail: "Interrupted")
                ])
            ], recordedAt: instant.addingTimeInterval(2)
        )
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScenarioCollectionStore(rootDirectory: root)
        try await store.saveCollection(collection, definitions: definitions)
        try await store.saveManifest(manifest, collection: collection)
        try await store.saveResult(result)

        let reloaded = ScenarioCollectionStore(rootDirectory: root)
        let savedCollection = try #require(await reloaded.loadCollection(id: collection.id, version: 1))
        let savedManifest = try #require(await reloaded.loadManifest(id: manifest.id))
        let savedResult = try #require(await reloaded.loadResult(id: result.id))
        let assessment = ScenarioCollectionService.assess(
            manifest: savedManifest, collection: savedCollection, result: savedResult, runs: [passing]
        )
        #expect(assessment.qualification == .incomplete)
        #expect(assessment.plannedCount == 3)
        #expect(assessment.passedCount == 1)
        #expect(assessment.coordinates.map(\.terminalState) == [.completed, .cancelled, .notRun])
        #expect(ScenarioCollectionService.failedCaseIDs(in: assessment).count == 2)
    }

    @Test func selectedRerunCannotBorrowOlderGreenRowsOrQualifyFullCollection() throws {
        let projectID = UUID()
        let definitions = try (0..<2).map { try caseDefinition(projectID: projectID, name: "Case \($0)") }
        let collection = try ScenarioCollection(projectID: projectID, name: "Regression",
                                                members: try definitions.map(ScenarioCollectionService.member))
        let baselineTime = Date(timeIntervalSince1970: 1_800_000_000)
        let baseline = try ScenarioCollectionService.freezeManifest(
            collection: collection, definitions: definitions, scope: .full,
            appProductDigest: "app-build", createdAt: baselineTime
        )
        let allFailedRerun = try ScenarioCollectionService.freezeFailedRerun(
            collection: collection, definitions: definitions,
            priorManifest: baseline, priorResult: nil, priorRuns: [],
            appProductDigest: "app-build", createdAt: baselineTime.addingTimeInterval(50)
        )
        #expect(allFailedRerun.scope == .rerunFailed)
        #expect(allFailedRerun.cases.count == 2)
        #expect(ScenarioCollectionService.assess(
            manifest: allFailedRerun, collection: collection, result: nil, runs: []
        ).qualification == .partial)
        let candidateTime = baselineTime.addingTimeInterval(100)
        let candidate = try ScenarioCollectionService.freezeManifest(
            collection: collection, definitions: definitions, scope: .rerunFailed,
            appProductDigest: "app-build",
            selectedCaseIDs: [definitions[0].id], priorBatchID: baseline.id,
            createdAt: candidateTime
        )
        #expect(candidate.coordinates.count == 1)
        let oldRun = run(for: definitions[0], coordinate: baseline.coordinates[0],
                         startedAt: baselineTime.addingTimeInterval(1), outcome: .passed)
        let coordinate = candidate.coordinates[0]
        let stale = ScenarioCollectionBatchResult(
            id: candidate.id, manifestID: candidate.id,
            executions: [try execution(manifest: candidate, caseID: coordinate.caseID, records: [
                .init(coordinate: coordinate, state: .completed, evidenceRunID: oldRun.id,
                      evidenceLaneResultID: oldRun.laneResults[0].id, detail: nil)
            ])],
            recordedAt: candidateTime.addingTimeInterval(1)
        )
        let staleAssessment = ScenarioCollectionService.assess(
            manifest: candidate, collection: collection, result: stale, runs: [oldRun]
        )
        #expect(staleAssessment.qualification == .partial)
        #expect(staleAssessment.passedCount == 0)
        #expect(staleAssessment.coordinates[0].reason?.contains("stale") == true)

        let freshRun = run(for: definitions[0], coordinate: coordinate,
                           startedAt: candidateTime.addingTimeInterval(1), outcome: .passed)
        let fresh = ScenarioCollectionBatchResult(
            id: candidate.id, manifestID: candidate.id,
            executions: [try execution(manifest: candidate, caseID: coordinate.caseID, records: [
                .init(coordinate: coordinate, state: .completed, evidenceRunID: freshRun.id,
                      evidenceLaneResultID: freshRun.laneResults[0].id, detail: nil)
            ])],
            recordedAt: candidateTime.addingTimeInterval(2)
        )
        let freshAssessment = ScenarioCollectionService.assess(
            manifest: candidate, collection: collection, result: fresh, runs: [freshRun, oldRun]
        )
        #expect(freshAssessment.passedCount == 1)
        #expect(freshAssessment.qualification == .partial)
        var siblingRouteFailed = freshRun
        siblingRouteFailed.outcome = .failed
        #expect(ScenarioCollectionService.assess(
            manifest: candidate, collection: collection, result: fresh,
            runs: [siblingRouteFailed]
        ).passedCount == 1)
        #expect(throws: ScenarioCollectionError.self) {
            _ = try ScenarioCollectionService.freezeManifest(
                collection: collection, definitions: definitions, scope: .full,
                appProductDigest: "app-build",
                selectedCaseIDs: [definitions[0].id]
            )
        }
    }

    @Test func approvedVariationBecomesSeparateReviewedCaseWithoutChangingSource() async throws {
        let projectID = UUID()
        let source = try caseDefinition(projectID: projectID, name: "Source")
        let collection = try ScenarioCollection(projectID: projectID, name: "Phrases",
                                                members: [ScenarioCollectionService.member(source)])
        let reviewedText = "Summarise the packing note in one sentence"
        let draft = ScenarioVariationDraft(
            id: UUID(), sourceCaseID: source.id, sourceVersion: source.version,
            requestText: reviewedText, parameters: source.directControl.parameters,
            featureInputs: [], outcomeReview: .sameOutcome
        )
        var reviewed = source
        reviewed.id = UUID()
        reviewed.definitionDigest = ""
        reviewed.testContractDigest = nil
        reviewed.goal.requestText = reviewedText
        reviewed.assertions = reviewed.assertions.map { assertion in
            var copy = assertion
            copy.id = UUID()
            return copy
        }
        let result = try ScenarioCollectionService.addingApprovedVariations(
            [.init(draft: draft, reviewedDefinition: reviewed)], source: source, to: collection
        )
        #expect(collection.version == 1)
        #expect(collection.members.count == 1)
        #expect(source.goal.requestText != reviewedText)
        #expect(result.collection.version == 2)
        #expect(result.collection.members.count == 2)
        #expect(result.cases[0].goal.requestText == reviewedText)
        #expect(result.collection.members[1].lineage?.approvedDraftID == draft.id)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScenarioCollectionStore(rootDirectory: root)
        try await store.saveCollection(collection, definitions: [source])
        try await store.saveCollection(result.collection, definitions: [source] + result.cases)
        let reloaded = ScenarioCollectionStore(rootDirectory: root)
        #expect(try await reloaded.loadCollection(id: collection.id, version: 2)?.members.count == 2)
        #expect(try await reloaded.loadCollections().count == 2)

        var changed = reviewed
        changed.id = UUID()
        changed.goal.expectedBehavior = "Change the note's title"
        let unreviewed = ScenarioApprovedVariation(draft: draft, reviewedDefinition: changed)
        #expect(throws: ScenarioCollectionError.self) {
            _ = try ScenarioCollectionService.addingApprovedVariations([unreviewed],
                                                                       source: source, to: collection)
        }
        var reviewedDifferent = changed
        reviewedDifferent.assertions[0].expectedValue = .string("changed-note-id")
        var differentDraft = draft
        differentDraft.outcomeReview = .differentOutcomeReviewed
        let changedResult = try ScenarioCollectionService.addingApprovedVariations(
            [.init(draft: differentDraft, reviewedDefinition: reviewedDifferent)],
            source: source, to: collection
        )
        #expect(changedResult.collection.members[1].lineage?.outcomeReview == .differentOutcomeReviewed)
        var changedCheck = reviewed
        changedCheck.id = UUID()
        changedCheck.assertions[0].expectedValue = .string("Different note")
        #expect(throws: ScenarioCollectionError.self) {
            _ = try ScenarioCollectionService.addingApprovedVariations(
                [.init(draft: draft, reviewedDefinition: changedCheck)], source: source, to: collection
            )
        }
        var unsupported = draft
        unsupported.unsupportedReason = "Multi-turn Siri is not supported"
        #expect(throws: ScenarioCollectionError.self) {
            _ = try ScenarioCollectionService.addingApprovedVariations(
                [.init(draft: unsupported, reviewedDefinition: reviewed)], source: source, to: collection
            )
        }
    }

    @Test func membershipDiffLabelsAddedRemovedAndChangedWithoutCallingDeletionImprovement() throws {
        let projectID = UUID()
        let a = try caseDefinition(projectID: projectID, name: "A")
        let b = try caseDefinition(projectID: projectID, name: "B")
        let c = try caseDefinition(projectID: projectID, name: "C")
        let baseline = try ScenarioCollection(projectID: projectID, name: "Cases",
                                              members: [ScenarioCollectionService.member(a),
                                                        ScenarioCollectionService.member(b)])
        var changedB = b
        changedB.version = 2
        changedB.goal.expectedBehavior = "A different expected outcome"
        changedB = try changedB.frozen()
        let candidate = try baseline.revised(members: [
            ScenarioCollectionService.member(changedB), ScenarioCollectionService.member(c)
        ])
        let difference = try ScenarioCollectionService.membershipDifference(
            baseline: baseline, candidate: candidate
        )
        #expect(difference.map(\.change) == [.removed, .changed, .added])
        #expect(difference.map(\.caseID) == [a.id, b.id, c.id])
        #expect(baseline.membershipDigest != candidate.membershipDigest)
    }

    @Test func featureCoordinateRequiresItsOwnFreshSealedChildEvidence() throws {
        let projectID = UUID()
        var definition = try caseDefinition(projectID: projectID, name: "Feature")
        definition.coverage = .init(appFeature: .required, intentIntegration: .notApplicable,
                                    siri: .notApplicable, siriAttemptCount: 1)
        definition.featureBinding = .init(featureID: "summarize", interfaceDigest: "interface",
                                           inputMapping: [], outputProjections: [])
        definition = try definition.frozen()
        let collection = try ScenarioCollection(projectID: projectID, name: "Feature checks",
                                                members: [ScenarioCollectionService.member(definition)])
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(throws: ScenarioCollectionError.self) {
            _ = try ScenarioCollectionService.freezeManifest(
                collection: collection, definitions: [definition], scope: .full,
                appProductDigest: "app-build", createdAt: instant
            )
        }
        let manifest = try ScenarioCollectionService.freezeManifest(
            collection: collection, definitions: [definition], scope: .full,
            appProductDigest: "app-build", subjectInputDigests: [definition.id: "input"],
            createdAt: instant
        )
        let coordinate = manifest.coordinates[0]
        let featureRunID = UUID()
        let featureSampleID = UUID()
        let lane = ScenarioLaneResult(caseID: definition.id, attempt: 1, lane: .appFeature,
                                      executionStatus: .completed, outcome: .passed,
                                      startedAt: instant.addingTimeInterval(1),
                                      completedAt: instant.addingTimeInterval(2),
                                      observations: [
                                          "feature.response": .string("The actual summary"),
                                          "feature.runID": .string(featureRunID.uuidString),
                                          "feature.sampleID": .string(featureSampleID.uuidString)
                                      ])
        let child = try ScenarioFeatureChildEvidence(
            runID: featureRunID, sampleID: featureSampleID,
            startedAt: instant.addingTimeInterval(1),
            completedAt: instant.addingTimeInterval(2), caseID: definition.id, attempt: 1,
            response: "The actual summary", encodedOutput: nil, encodedOutputTypeName: nil,
            outputMetadata: [:], errorCategory: nil, errorMessage: nil,
            appBundleIdentifier: definition.target.bundleIdentifier, featureID: "summarize",
            featureVersion: "1", checkedAppProductDigest: "app-build", runnerBuildID: "app-build",
            fixtureContractDigest: definition.fixture.digest, subjectInputDigest: "input", digest: ""
        ).sealed()
        let row = ScenarioExecutionCoordinateRecord(
            coordinate: coordinate, state: .completed, evidenceRunID: child.runID,
            evidenceLaneResultID: lane.id, detail: nil, laneResult: lane, featureChild: child
        )
        let result = ScenarioCollectionBatchResult(
            id: manifest.id, manifestID: manifest.id,
            executions: [try execution(manifest: manifest, caseID: definition.id, records: [row])],
            recordedAt: instant.addingTimeInterval(3)
        )
        let assessment = ScenarioCollectionService.assess(
            manifest: manifest, collection: collection, result: result, runs: []
        )
        #expect(assessment.qualification == .passedFull)
        #expect(assessment.passedCount == 1)

        var stale = child
        stale.startedAt = instant.addingTimeInterval(-10)
        stale.completedAt = instant.addingTimeInterval(-9)
        stale = try stale.sealed()
        var staleRow = row
        staleRow.featureChild = stale
        let staleResult = ScenarioCollectionBatchResult(
            id: manifest.id, manifestID: manifest.id,
            executions: [try execution(manifest: manifest, caseID: definition.id, records: [staleRow])],
            recordedAt: instant.addingTimeInterval(3)
        )
        let rejected = ScenarioCollectionService.assess(
            manifest: manifest, collection: collection, result: staleResult, runs: []
        )
        #expect(rejected.qualification == .incomplete)
        #expect(rejected.passedCount == 0)

        var detachedRow = row
        detachedRow.laneResult?.observations["feature.response"] = .string("Another response")
        let detachedResult = ScenarioCollectionBatchResult(
            id: manifest.id, manifestID: manifest.id,
            executions: [try execution(manifest: manifest, caseID: definition.id, records: [detachedRow])],
            recordedAt: instant.addingTimeInterval(3)
        )
        #expect(ScenarioCollectionService.assess(
            manifest: manifest, collection: collection, result: detachedResult, runs: []
        ).passedCount == 0)

        var unboundInput = child
        unboundInput.subjectInputDigest = nil
        unboundInput = try unboundInput.sealed()
        var unboundRow = row
        unboundRow.featureChild = unboundInput
        let unboundResult = ScenarioCollectionBatchResult(
            id: manifest.id, manifestID: manifest.id,
            executions: [try execution(manifest: manifest, caseID: definition.id, records: [unboundRow])],
            recordedAt: instant.addingTimeInterval(3)
        )
        #expect(ScenarioCollectionService.assess(
            manifest: manifest, collection: collection, result: unboundResult, runs: []
        ).passedCount == 0)
    }

    @Test func localFeatureBatchUsesAcceptedNativeEvidenceAndFreezesRerunBackend() throws {
        let projectID = UUID()
        var definition = try caseDefinition(projectID: projectID, name: "Local Feature")
        definition.coverage = .init(appFeature: .required, intentIntegration: .notApplicable,
                                    siri: .notApplicable, siriAttemptCount: 1)
        definition.featureBinding = .init(featureID: "summarize",
                                           interfaceDigest: String(repeating: "a", count: 64),
                                           inputMapping: [], outputProjections: [])
        definition = try definition.frozen()
        let collection = try ScenarioCollection(
            projectID: projectID, name: "Local Feature checks",
            members: [ScenarioCollectionService.member(definition)]
        )
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let manifest = try ScenarioCollectionService.freezeManifest(
            collection: collection, definitions: [definition], scope: .full,
            appProductDigest: "app-build", subjectInputDigests: [definition.id: "input"],
            featureBackend: .projectLocalTestControl, createdAt: instant
        )
        #expect(manifest.selectedFeatureBackend == .projectLocalTestControl)
        var legacy = manifest
        legacy.featureBackend = nil
        legacy.manifestDigest = try legacy.calculatedDigest()
        let decodedLegacy = try JSONDecoder().decode(
            ScenarioCollectionBatchManifest.self, from: JSONEncoder().encode(legacy)
        )
        #expect(decodedLegacy.featureBackend == nil)
        #expect(decodedLegacy.selectedFeatureBackend == .connectedRunner)
        #expect(decodedLegacy.hasValidDigest)
        let coordinate = try #require(manifest.coordinates.first)
        var run = run(for: definition, coordinate: coordinate,
                      startedAt: instant.addingTimeInterval(1), outcome: .passed)
        run.id = run.invocation.id
        run.invocation.featureBackend = .projectLocalTestControl
        run.fixture = definition.fixture
        run.acceptanceStatus = .accepted
        run.executedTestCount = 1
        run.xctestExitCode = 0
        run.laneResults[0].observations["feature.response"] = .string("A summary")
        run.laneResults[0].observationSources = ["feature.response": .testOnlyIntent]
        let lane = run.laneResults[0]
        let row = ScenarioExecutionCoordinateRecord(
            coordinate: coordinate, state: .completed,
            evidenceRunID: run.id, evidenceLaneResultID: lane.id,
            detail: nil, laneResult: lane
        )
        let result = ScenarioCollectionBatchResult(
            id: manifest.id, manifestID: manifest.id,
            executions: [try execution(manifest: manifest, caseID: definition.id, records: [row])],
            recordedAt: instant.addingTimeInterval(2)
        )
        var journal = ScenarioExecutionJournal(
            phase: .stopped, invocation: run.invocation,
            scenarioID: definition.id, scenarioVersion: definition.version,
            resultBundlePath: "result", derivedDataPath: "derived", buildLogPath: "build",
            intendedExecutable: "xcodebuild", intendedArguments: [],
            processIdentifier: nil, processStartedAt: nil,
            updatedAt: instant.addingTimeInterval(2), recoveryReason: nil,
            evidenceAccepted: true, scope: .init(lane: .appFeature, attempt: 1)
        )
        #expect(ScenarioCollectionService.assess(
            manifest: manifest, collection: collection, result: result,
            runs: [run], journals: [journal]
        ).qualification == .passedFull)
        #expect(ScenarioCollectionService.assess(
            manifest: manifest, collection: collection, result: result,
            runs: [run]
        ).passedCount == 0)
        journal.evidenceAccepted = false
        #expect(ScenarioCollectionService.assess(
            manifest: manifest, collection: collection, result: result,
            runs: [run], journals: [journal]
        ).passedCount == 0)
        var connected = manifest
        connected.featureBackend = .connectedRunner
        connected.manifestDigest = try connected.calculatedDigest()
        #expect(ScenarioCollectionService.assess(
            manifest: connected, collection: collection, result: result,
            runs: [run], journals: []
        ).passedCount == 0)

        let rerun = try ScenarioCollectionService.freezeFailedRerun(
            collection: collection, definitions: [definition],
            priorManifest: manifest, priorResult: nil, priorRuns: [],
            appProductDigest: "app-build", subjectInputDigests: [definition.id: "input"],
            createdAt: instant.addingTimeInterval(3)
        )
        #expect(rerun.selectedFeatureBackend == .projectLocalTestControl)
        #expect(rerun.scope == .rerunFailed)
    }

    private func caseDefinition(projectID: UUID, name: String) throws -> ScenarioDefinition {
        var definition = ScenarioDefinition.starter(projectID: projectID)
        definition.id = UUID()
        definition.name = name
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.goal.requestText = "Open \(name)"
        definition.coverage = .init(appFeature: .notApplicable, intentIntegration: .required,
                                    siri: .notApplicable, siriAttemptCount: 1)
        return try definition.frozen()
    }

    private func run(for definition: ScenarioDefinition, coordinate: ScenarioPlannedCoordinate,
                     startedAt: Date, outcome: ScenarioOutcome) -> ScenarioRun {
        let invocation = ScenarioInvocationIdentity(
            id: UUID(), nonce: "test", issuedAt: startedAt,
            testIdentity: .init(bundleIdentifier: "tests", className: "Fixture", methodName: "test"),
            harnessVersion: "intent-lab-v2", destinationIdentifier: "test",
            scenarioDigest: definition.definitionDigest, resultBundleIdentity: "test",
            appProduct: .init(bundleIdentifier: definition.target.bundleIdentifier,
                              executableName: "Fixture", sha256: "app-build"), testProduct: nil
        )
        let environment = ScenarioEnvironment(
            xcodeVersion: "27", sdkVersion: "27", deviceModel: "test",
            operatingSystem: "test", operatingSystemBuild: nil,
            languageCode: "en-GB", regionCode: "GB", timeZoneIdentifier: "UTC",
            siriConfiguration: nil, siriConfigurationSource: nil, executedAt: startedAt
        )
        let lane = ScenarioLaneResult(
            caseID: coordinate.caseID, attempt: coordinate.repetition,
            lane: coordinate.lane, executionStatus: .completed, outcome: outcome,
            startedAt: startedAt, completedAt: startedAt,
            diagnostic: outcome == .passed ? nil : "Observed failure"
        )
        return ScenarioRun(
            id: UUID(), scenarioID: definition.id, scenarioVersion: definition.version,
            scenarioDigest: definition.definitionDigest, invocation: invocation,
            startedAt: startedAt, completedAt: startedAt, environment: environment,
            executionStatus: .completed, outcome: outcome, laneResults: [lane],
            linkedFeatureRunID: nil, importedAt: startedAt,
            scenarioSchemaVersion: ScenarioDefinition.stableSchemaVersion,
            testContractDigest: definition.testContractDigest
        )
    }

    private func execution(manifest: ScenarioCollectionBatchManifest, caseID: UUID,
                           records: [ScenarioExecutionCoordinateRecord]) throws -> ScenarioExecutionRecord {
        let snapshot = manifest.cases.first { $0.id == caseID }!
        let plan = ScenarioExecutionPlan(
            id: snapshot.executionPlanID, definitionID: caseID,
            definitionVersion: snapshot.member.version,
            definitionDigest: snapshot.member.definitionDigest,
            testContractDigest: snapshot.member.testContractDigest,
            profile: .init(id: UUID(), projectPath: "fixture", scheme: "Fixture",
                           testTarget: "FixtureTests", destinationIdentifier: "test",
                           signingSelection: nil,
                           featureBackend: manifest.selectedFeatureBackend),
            appProductDigest: manifest.appProductDigest, testProductDigest: "test-build",
            fixtureContractDigest: snapshot.fixtureContractDigest,
            coordinates: manifest.coordinates.filter { $0.caseID == caseID },
            comparisonPolicy: nil, createdAt: manifest.createdAt
        )
        return try .make(plan: plan, records: records,
                         completedAt: manifest.createdAt.addingTimeInterval(2))
    }
}
