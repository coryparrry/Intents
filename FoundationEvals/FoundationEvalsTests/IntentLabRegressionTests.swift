import Foundation
import Testing
import Darwin
@testable import FoundationEvals

struct IntentLabRegressionTests {
    @Test func testProcessDeadlineIncludesDirectLaneButOmitsNotApplicableSiri() {
        let definition = deadlineDefinition(
            directLane: true,
            siriLane: false,
            siriAttemptCount: 3,
            deadlineSeconds: 60
        )

        #expect(XcodeTestDeadlineBudget.seconds(for: definition) == 255)
    }

    @Test func testProcessDeadlineBudgetsThreeSiriAttemptsAndDirectLane() {
        let definition = deadlineDefinition(
            directLane: true,
            siriLane: true,
            siriAttemptCount: 3,
            deadlineSeconds: 60
        )

        #expect(XcodeTestDeadlineBudget.seconds(for: definition) == 660)
    }

    @Test func testProcessDeadlineUsesConfiguredScenarioWaitForEveryLane() {
        let definition = deadlineDefinition(
            directLane: true,
            siriLane: true,
            siriAttemptCount: 3,
            deadlineSeconds: 30
        )

        #expect(XcodeTestDeadlineBudget.seconds(for: definition) == 480)
    }

    @MainActor
    @Test func siriCoverageRequiresPhysicalIPhoneButDirectChecksAllowMac() {
        let mac = IntentLabDeviceDestination(
            identifier: "mac-1", name: "Mac", operatingSystemVersion: "27.0",
            available: true, platform: .macOS
        )
        let phone = IntentLabDeviceDestination(
            identifier: "phone-1", name: "iPhone", operatingSystemVersion: "27.0",
            available: true, platform: .iOS
        )
        let simulator = IntentLabDeviceDestination(
            identifier: "sim-1", name: "iPhone Simulator", operatingSystemVersion: "27.0",
            available: true, platform: .iOSSimulator
        )
        let devices = [mac, phone, simulator]

        #expect(XcodeTestExecutor.destinationStatus(identifier: mac.identifier, devices: devices).ready)
        let rejected = XcodeTestExecutor.destinationStatus(
            identifier: mac.identifier, devices: devices, requiresSiri: true
        )
        #expect(!rejected.ready)
        #expect(rejected.detail.contains("physical iPhone"))
        #expect(XcodeTestExecutor.destinationStatus(
            identifier: phone.identifier, devices: devices, requiresSiri: true
        ).ready)
        #expect(XcodeTestExecutor.destinationStatus(
            identifier: simulator.identifier, devices: devices
        ).ready)
        #expect(!XcodeTestExecutor.destinationStatus(
            identifier: simulator.identifier, devices: devices, requiresSiri: true
        ).ready)
        #expect(ScenarioCoordinator.availablePlatform(for: simulator.identifier, in: devices) == .iOSSimulator)
        #expect(ScenarioCoordinator.availablePlatform(for: phone.identifier, in: devices) == .iOS)
        #expect(ScenarioCoordinator.availablePlatform(for: "stale-id", in: devices) == nil)
    }

    @Test func simulatorSigningRequiresSelectedSimulatorAndVerifiedAdHocProducts() {
        var configuration = XcodeTestConfiguration(
            containerPath: "/tmp/Fixture.xcodeproj", isWorkspace: false, scheme: "Fixture",
            testTarget: "FixtureUITests", testBundleIdentifier: "dev.example.FixtureUITests",
            destinationIdentifier: "sim-1", generatedResourceDirectory: "/tmp"
        )
        configuration.destinationPlatform = .iOSSimulator
        #expect(configuration.signingArguments == [
            "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_ALLOWED=YES", "DEVELOPMENT_TEAM="
        ])
        #expect(XcodeTestExecutor.signingDestinationMatchesSelection(
            configuration: configuration, destinationPlatform: .iOSSimulator
        ))
        #expect(!XcodeTestExecutor.signingDestinationMatchesSelection(
            configuration: configuration, destinationPlatform: .iOS
        ))
        #expect(!XcodeTestExecutor.signingDestinationMatchesSelection(
            configuration: configuration, destinationPlatform: nil
        ))
        #expect(XcodeTestExecutor.signingReady(
            configuration: configuration, destinationPlatform: .iOSSimulator,
            reusableConnectionVerified: true
        ))
        #expect(!XcodeTestExecutor.signingReady(
            configuration: configuration, destinationPlatform: .iOS,
            reusableConnectionVerified: true
        ))
        #expect(XcodeTestExecutor.signingAcceptedForReadiness(
            configuration: configuration, runtimePlatform: .iOSSimulator,
            appTeam: nil, hostTeam: nil, testTeam: nil, adHocSignaturesValid: true
        ))
        #expect(!XcodeTestExecutor.signingAcceptedForReadiness(
            configuration: configuration, runtimePlatform: .iOS,
            appTeam: nil, hostTeam: nil, testTeam: nil, adHocSignaturesValid: true
        ))
        #expect(!XcodeTestExecutor.signingAcceptedForReadiness(
            configuration: configuration, runtimePlatform: .iOSSimulator,
            appTeam: nil, hostTeam: nil, testTeam: nil, adHocSignaturesValid: false
        ))

        configuration.destinationIdentifier = "phone-1"
        configuration.destinationPlatform = .iOS
        #expect(configuration.signingArguments.isEmpty)
        #expect(!XcodeTestExecutor.signingAcceptedForReadiness(
            configuration: configuration, runtimePlatform: .iOS,
            appTeam: nil, hostTeam: nil, testTeam: nil, adHocSignaturesValid: true
        ))
    }

    @Test func simulatorRuntimeProfileUsesOnlyTheBootedSelectedDevice() {
        let listing = Data("""
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[
          {"udid":"sim-1","state":"Booted"},
          {"udid":"sim-2","state":"Shutdown"}
        ],"com.apple.CoreSimulator.SimRuntime.iOS-26-4":[
          {"udid":"sim-3","state":"Booted"}
        ]}}
        """.utf8)
        let selected = IntentLabDeviceDestination(
            identifier: "sim-1", name: "Simulator", operatingSystemVersion: nil,
            available: true, platform: .iOSSimulator
        )
        #expect(XcodeTestExecutor.destinationOSVersion(
            for: selected, simulatorListing: listing
        ) == "27.0")
        var reported = selected
        reported.operatingSystemVersion = "27.1"
        #expect(XcodeTestExecutor.destinationOSVersion(
            for: reported, simulatorListing: listing
        ) == "27.1")
        #expect(XcodeTestExecutor.simulatorOSVersion(identifier: "sim-1", listing: listing) == "27.0")
        #expect(XcodeTestExecutor.simulatorOSVersion(identifier: "sim-2", listing: listing) == nil)
        #expect(XcodeTestExecutor.simulatorOSVersion(identifier: "missing", listing: listing) == nil)
        #expect(XcodeTestExecutor.simulatorOSVersion(identifier: "sim-1", listing: Data("{}".utf8)) == nil)
    }

    @Test func connectionFingerprintChangesWithSourceAndResourceEdits() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appending(path: "Fixture.xcodeproj", directoryHint: .isDirectory)
        let products = root.appending(path: "Products", directoryHint: .isDirectory)
        let app = products.appending(path: "Fixture.app", directoryHint: .isDirectory)
        let tests = products.appending(path: "FixtureUITests.xctest", directoryHint: .isDirectory)
        for directory in [project, app, tests] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("project".utf8).write(to: project.appending(path: "project.pbxproj"))
        let source = root.appending(path: "Sources/NoteIntent.swift")
        let resource = root.appending(path: "Resources/NoteTemplate.json")
        for file in [source, resource] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("original".utf8).write(to: file)
        }
        let testRun = products.appending(path: "Fixture.xctestrun")
        try Data("run".utf8).write(to: testRun)
        let paths = XCTestRunProductPaths(
            sourceURL: testRun, appBundleURL: app, testHostURL: tests, testBundleURL: tests
        )
        let configuration = XcodeTestConfiguration(
            containerPath: project.path, isWorkspace: false, scheme: "Fixture",
            testTarget: "FixtureUITests", testBundleIdentifier: "dev.example.FixtureUITests",
            destinationIdentifier: "device", generatedResourceDirectory: root.path,
            xcodebuildPath: "/bin/echo"
        )

        let original = try XcodeTestExecutor.buildInputsDigest(configuration: configuration, products: paths)
        try Data("changed source".utf8).write(to: source)
        let afterSource = try XcodeTestExecutor.buildInputsDigest(configuration: configuration, products: paths)
        #expect(afterSource != original)
        try Data("changed resource".utf8).write(to: resource)
        #expect(try XcodeTestExecutor.buildInputsDigest(configuration: configuration, products: paths) != afterSource)
    }

    @Test func xcresultManifestFindsUUIDExportsAndPrefersFinalEvidence() throws {
        let invocationID = UUID()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let checkpointFile = "\(UUID().uuidString).json"
        let finalFile = "\(UUID().uuidString).json"
        try Data("{}".utf8).write(to: root.appending(path: checkpointFile))
        try Data("{}".utf8).write(to: root.appending(path: finalFile))
        func manifest(_ names: [String]) throws -> Data {
            try JSONSerialization.data(withJSONObject: [[
                "testIdentifier": "IntentLabScenarioTests/testIntentLabScenario()",
                "attachments": names.map { name in
                    ["exportedFileName": name == "checkpoint" ? checkpointFile : finalFile,
                     "suggestedHumanReadableName": "IntentLabEvidence-\(invocationID.uuidString)-\(name)_0_\(UUID().uuidString).json"]
                },
            ]])
        }

        let checkpoint = XcodeTestExecutor.evidenceAttachments(
            in: try manifest(["checkpoint"]), root: root, invocationID: invocationID
        )
        #expect(checkpoint.map(\.url.lastPathComponent) == [checkpointFile])
        #expect(checkpoint.first?.isCheckpoint == true)
        let preferred = XcodeTestExecutor.evidenceAttachments(
            in: try manifest(["checkpoint", "final"]), root: root, invocationID: invocationID
        )
        #expect(preferred.map(\.url.lastPathComponent) == [finalFile])
    }

    @Test func xcresultScreenshotExportsKeepEnvelopeFilenamesAndBytes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let exported = "\(UUID().uuidString).png"
        let bytes = Data("screenshot-bytes".utf8)
        try bytes.write(to: root.appending(path: exported))
        let manifest = try JSONSerialization.data(withJSONObject: [[
            "testIdentifier": "IntentLabScenarioTests/testIntentLabScenario()",
            "attachments": [["exportedFileName": exported,
                "suggestedHumanReadableName": "IntentLabArtifact-\(id.uuidString)_0.png"]],
        ]])
        try XcodeTestExecutor.restoreArtifactFilenames(in: manifest, root: root)
        #expect(try Data(contentsOf: root.appending(path: "IntentLabArtifact-\(id.uuidString).png")) == bytes)
    }

    @Test func xcresultFailureMessageIsExtractedWithoutPromotingItToEvidence() {
        let nodes: [String: Any] = [
            "testNodes": [["children": [[
                "nodeType": "Failure Message",
                "name": "Timed out waiting for Siri to activate",
            ]]]]
        ]
        #expect(XcodeTestExecutor.failureMessages(in: nodes) == ["Timed out waiting for Siri to activate"])
        #expect(ScenarioDiagnosticClassifier.checkpointDiagnostic(for: "Timed out waiting for Siri to activate")
            .contains("approve it, then rerun"))
    }

    @Test func failedIntentWithoutFeatureEvidenceDoesNotClaimFeaturePassed() {
        let message = ScenarioDiagnosticClassifier.message(for: [lane(.intentIntegration, .failed)])
        #expect(message.contains("No passing app-feature control was recorded"))
        #expect(!message.contains("feature control passed"))

        let unobservedMessage = ScenarioDiagnosticClassifier.message(for: [
            lane(.appFeature, .notObserved), lane(.intentIntegration, .failed)
        ])
        #expect(unobservedMessage.contains("No passing app-feature control was recorded"))
    }

    @Test func passingFeatureControlCanLocateFailedIntentBoundary() {
        let message = ScenarioDiagnosticClassifier.message(for: [
            lane(.appFeature, .passed), lane(.intentIntegration, .failed)
        ])
        #expect(message.contains("The feature control passed"))
    }

    private func lane(_ lane: ScenarioLane, _ outcome: ScenarioOutcome) -> ScenarioLaneResult {
        ScenarioLaneResult(
            caseID: UUID(), attempt: 1, lane: lane,
            executionStatus: .completed, outcome: outcome,
            startedAt: Date(), completedAt: Date()
        )
    }

    @Test func injectedSemanticAssessmentFinalizesLaneAndRunOutcome() async throws {
        var definition = ScenarioDefinition.starter()
        let assertion = ScenarioAssertion(
            kind: .semanticRubric,
            observationKey: "specificResponse",
            explanation: "The response confirms that the packing note opened.",
            applicableLanes: [.siri]
        )
        definition.assertions = [assertion]
        definition.coverage.intentIntegration = .notApplicable
        definition = try definition.frozen()
        let now = Date()
        let invocation = ScenarioInvocationIdentity(
            id: UUID(),
            nonce: UUID().uuidString,
            issuedAt: now,
            testIdentity: .init(
                bundleIdentifier: "dev.example.FixtureUITests",
                className: "IntentLabScenarioTests",
                methodName: "testIntentLabScenario"
            ),
            harnessVersion: ScenarioInvocationIdentity.currentHarnessVersion,
            destinationIdentifier: "physical-device-1",
            scenarioDigest: definition.definitionDigest,
            resultBundleIdentity: UUID().uuidString
        )
        let run = ScenarioRun(
            id: invocation.id,
            scenarioID: definition.id,
            scenarioVersion: definition.version,
            scenarioDigest: definition.definitionDigest,
            invocation: invocation,
            startedAt: now,
            completedAt: now,
            environment: .init(
                xcodeVersion: "27", sdkVersion: "27", deviceModel: "iPhone",
                operatingSystem: "iOS 27", languageCode: "en", regionCode: "GB",
                timeZoneIdentifier: "Europe/London", executedAt: now
            ),
            executionStatus: .completed,
            outcome: .needsReview,
            laneResults: [.init(
                caseID: definition.id,
                attempt: 1,
                lane: .siri,
                executionStatus: .completed,
                outcome: .needsReview,
                startedAt: now,
                completedAt: now,
                observations: ["specificResponse": .string("Opened the packing note"), "visibleResponse": .string("Unrelated response")],
                assertionResults: [.init(
                    assertionID: assertion.id,
                    passed: false,
                    observedValue: .string("Opened the packing note"),
                    message: "Pending semantic review."
                )]
            )],
            linkedFeatureRunID: nil,
            importedAt: now
        )

        let assessed = try await ScenarioResponseAssessmentService.assess(
            run,
            definition: definition
        ) { receivedAssertion, response, _ in
            #expect(receivedAssertion.id == assertion.id)
            #expect(response == "Opened the packing note")
            return ScenarioSemanticAssessment(passed: true, explanation: "The response satisfies the rubric.")
        }

        #expect(assessed.laneResults[0].outcome == .passed)
        #expect(assessed.laneResults[0].assertionResults[0].passed)
        #expect(assessed.outcome == .passed)
        #expect(assessed.responseAssessments?.first?.passed == true)
    }

    @MainActor
    @Test func frozenExecutionDefinitionSurvivesLaterDraftEdits() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvaluationStore(supportDirectory: root)
        let coordinator = ScenarioCoordinator(supportDirectory: root, evaluationStore: store)
        coordinator.configuration.containerPath = "/tmp/Fixture.xcodeproj"
        coordinator.configuration.destinationIdentifier = "physical-device-1"
        coordinator.configuration.generatedResourceDirectory = "/tmp/Generated"
        let frozen = try await coordinator.freezeAndSave()
        coordinator.draft.goal.requestText = "A different request while the device is running"
        #expect(frozen.goal.requestText != coordinator.draft.goal.requestText)
        #expect(coordinator.definitions.first?.definitionDigest == frozen.definitionDigest)
        #expect(coordinator.definitions.first?.goal.requestText == frozen.goal.requestText)
    }

    @MainActor
    @Test func ordinaryRunAndScenarioStartsDoNotShareTheExecutionDestination() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let evaluation = EvaluationStore(supportDirectory: root)
        let runners = DeveloperRunnerStore(evaluationStore: evaluation)
        let coordinator = ScenarioCoordinator(supportDirectory: root, evaluationStore: evaluation)
        coordinator.bindRunnerStore(runners)
        await coordinator.load()
        #expect(coordinator.hasLoaded)

        evaluation.isRunning = true
        await coordinator.run()
        #expect(coordinator.notice?.contains("active evaluation") == true)
        #expect(!coordinator.isRunning)
        #expect(ScenarioExecutionAdmission.shared.ownerID == nil)
        evaluation.isRunning = false

        let ordinaryRunnerID = UUID()
        runners.startTrackedExecution(runID: ordinaryRunnerID) {
            try? await Task.sleep(for: .seconds(30))
        }
        #expect(runners.executingRunID == ordinaryRunnerID)
        coordinator.notice = nil
        await coordinator.run()
        #expect(coordinator.notice?.contains("active evaluation") == true)
        #expect(ScenarioExecutionAdmission.shared.ownerID == nil)
        runners.cancelRun(ordinaryRunnerID)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while runners.executingRunID != nil && ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(runners.executingRunID == nil)

        let scenarioOwner = UUID()
        try ScenarioExecutionAdmission.shared.acquire(scenarioOwner)
        defer { ScenarioExecutionAdmission.shared.release(scenarioOwner) }
        do {
            _ = try evaluation.startRun(id: UUID(), expectedRevision: "unused")
            Issue.record("An ordinary evaluation started while the scenario owned the destination.")
        } catch EvaluationStoreError.resourceConflict(let message) {
            #expect(message.contains("coordinated execution"))
        } catch {
            Issue.record("The ordinary evaluation failed for a reason other than admission: \(error)")
        }
        do {
            _ = try runners.runSelectedSuite(on: UUID(), featureID: "unused")
            Issue.record("A developer runner started while the scenario owned the destination.")
        } catch EvaluationStoreError.resourceConflict(let message) {
            #expect(message.contains("Another evaluation is already running"))
        } catch {
            Issue.record("The developer runner failed for a reason other than admission: \(error)")
        }
        #expect(runners.executingRunID == nil)
    }

    @MainActor
    @Test func savedBatchExportRetainsFullMembershipAndOnlyFreshCaseEvidence() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvaluationStore(supportDirectory: root)
        let intentLabRoot = root.appending(path: "IntentLab", directoryHint: .isDirectory)
        let persistence = ScenarioPersistence(rootDirectory: intentLabRoot)
        let collectionStore = ScenarioCollectionStore(rootDirectory: intentLabRoot)
        let projectID = UUID()
        let first = try collectionDefinition(projectID: projectID, name: "First check")
        let second = try collectionDefinition(projectID: projectID, name: "Second check")
        let collection = try ScenarioCollection(
            projectID: projectID, name: "Regression checks",
            members: [try ScenarioCollectionService.member(first),
                      try ScenarioCollectionService.member(second)]
        )
        let manifest = try ScenarioCollectionService.freezeManifest(
            collection: collection, definitions: [first, second], scope: .selected,
            appProductDigest: "checked-app", selectedCaseIDs: [first.id]
        )
        let batchCase = try #require(manifest.cases.first)
        let plan = try ScenarioExecutionPlan.make(
            definition: first,
            profile: .init(id: UUID(), projectPath: "/example/App.xcodeproj",
                           scheme: "App", testTarget: "AppTests",
                           destinationIdentifier: "device", signingSelection: nil,
                           trustedConnectionID: nil, buildConfiguration: "Debug"),
            appProductDigest: manifest.appProductDigest, testProductDigest: "checked-tests",
            sourceInputsDigest: "checked-source", runnerBuildID: nil, runnerID: nil,
            plannedCoordinates: manifest.coordinates, id: batchCase.executionPlanID,
            createdAt: manifest.createdAt
        )
        let record = try ScenarioExecutionRecord.make(
            plan: plan, records: plan.coordinates.map(ScenarioExecutionCoordinateRecord.unstarted)
        )
        let result = ScenarioCollectionBatchResult(
            id: manifest.id, manifestID: manifest.id,
            executions: [record], recordedAt: Date()
        )
        try await persistence.saveDefinition(first)
        try await persistence.saveDefinition(second)
        try await persistence.savePlan(plan)
        try await persistence.saveExecutionRecord(record)
        try await collectionStore.saveCollection(collection, definitions: [first, second])
        try await collectionStore.saveManifest(manifest, collection: collection)
        try await collectionStore.saveResult(result)

        let coordinator = ScenarioCoordinator(supportDirectory: root, evaluationStore: store)
        await coordinator.load()
        #expect(coordinator.hasLoaded)
        let destination = root.appending(path: "partial.intentlabrun")
        try await coordinator.exportSelectedBatch(to: destination)
        let imported = try IntentEvidenceBundle.read(destination)
        #expect(imported.requirements.cases.count == 2)
        #expect(imported.cases.map(\.definition.id) == [first.id])
        #expect(imported.batchManifest?.id == manifest.id)
        #expect(imported.batchResult?.executions.map(\.id) == [record.id])
    }

    @MainActor
    @Test func collectionRevisionKeepsOldMembershipAndShowsAddedRemovedChangedCases() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvaluationStore(supportDirectory: root)
        let persistence = ScenarioPersistence(rootDirectory: root.appending(path: "IntentLab"))
        let projectID = UUID()
        let first = try collectionDefinition(projectID: projectID, name: "First")
        let second = try collectionDefinition(projectID: projectID, name: "Second")
        let third = try collectionDefinition(projectID: projectID, name: "Third")
        for definition in [first, second, third] {
            try await persistence.saveDefinition(definition)
        }
        let coordinator = ScenarioCoordinator(supportDirectory: root, evaluationStore: store)
        await coordinator.load()
        let baseline = try await coordinator.createCollection(
            name: "Regression", caseIDs: [first.id, second.id]
        )
        let unchanged = try await coordinator.reviseSelectedCollection(
            caseIDs: [first.id, second.id]
        )
        #expect(unchanged == baseline)

        let revised = try await coordinator.reviseSelectedCollection(
            caseIDs: [second.id, third.id]
        )
        #expect(revised.version == 2)
        let difference = try ScenarioCollectionService.membershipDifference(
            baseline: baseline, candidate: revised
        )
        #expect(difference.first(where: { $0.caseID == first.id })?.change == .removed)
        #expect(difference.first(where: { $0.caseID == second.id })?.change == .unchanged)
        #expect(difference.first(where: { $0.caseID == third.id })?.change == .added)

        var changedSecond = second
        changedSecond.version = 2
        changedSecond.assertions[0].expectedValue = .string("different-note")
        changedSecond = try changedSecond.frozen()
        try await persistence.saveDefinition(changedSecond)
        let changed = try await coordinator.reviseSelectedCollection(
            caseIDs: [second.id, third.id]
        )
        #expect(changed.version == 3)
        let nextDifference = try ScenarioCollectionService.membershipDifference(
            baseline: revised, candidate: changed
        )
        #expect(nextDifference.first(where: { $0.caseID == second.id })?.change == .changed)
        #expect(nextDifference.first(where: { $0.caseID == third.id })?.change == .unchanged)
        let collectionStore = ScenarioCollectionStore(rootDirectory: root.appending(path: "IntentLab"))
        #expect(try await collectionStore.loadCollection(id: baseline.id, version: 1) == baseline)
        #expect(try await collectionStore.loadCollection(id: baseline.id, version: 2) == revised)
        #expect(try await collectionStore.loadCollection(id: baseline.id, version: 3) == changed)
    }

    @MainActor
    @Test func corruptRecoveryJournalPreventsScenarioRun() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journals = root.appending(path: "IntentLab/Journals", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: true)
        try Data("invalid journal".utf8).write(to: journals.appending(path: "corrupt.json"))
        let store = EvaluationStore(supportDirectory: root)
        let coordinator = ScenarioCoordinator(supportDirectory: root, evaluationStore: store)

        await coordinator.load()
        #expect(!coordinator.hasLoaded)
        await coordinator.run()
        #expect(coordinator.notice?.contains("must load successfully") == true)
        let saved = try await ScenarioPersistence(rootDirectory: root.appending(path: "IntentLab"))
            .loadDefinitions()
        #expect(saved.isEmpty)
    }

    @MainActor
    @Test func approvingWordingCreatesANewFrozenVersion() async throws {
        let root = try temporaryDirectory()
        let store = EvaluationStore(supportDirectory: root)
        let coordinator = ScenarioCoordinator(supportDirectory: root, evaluationStore: store)
        await coordinator.load()
        coordinator.configuration.containerPath = "/tmp/Fixture.xcodeproj"
        coordinator.configuration.destinationIdentifier = "physical-device-1"
        coordinator.configuration.generatedResourceDirectory = "/tmp/Generated"
        try await coordinator.freezeAndSave()
        let originalVersion = coordinator.draft.version

        coordinator.approveSuggestion(.init(
            requestText: "Open my packing note in the fixture app",
            category: "paraphrase",
            note: "Approved alternate wording"
        ))

        #expect(coordinator.draft.version == originalVersion + 1)
        #expect(coordinator.draft.definitionDigest.isEmpty)
        #expect(coordinator.draft.goal.requestText == "Open my packing note in the fixture app")

        try await coordinator.freezeAndSave()
        let reloaded = ScenarioPersistence(
            rootDirectory: store.overviewStorageDirectory.appending(path: "IntentLab", directoryHint: .isDirectory)
        )
        let saved = try await reloaded.loadDefinitions().filter { $0.id == coordinator.draft.id }
        #expect(saved.map(\.version).sorted() == [originalVersion, originalVersion + 1])
        #expect(saved.last(where: { $0.version == originalVersion + 1 })?.goal.requestText == "Open my packing note in the fixture app")
    }

    @MainActor
    @Test func executionSetupReloadsButProjectTrustDoesNot() async throws {
        let root = try temporaryDirectory()
        let store = EvaluationStore(supportDirectory: root)
        let persistence = ScenarioPersistence(
            rootDirectory: store.overviewStorageDirectory.appending(path: "IntentLab", directoryHint: .isDirectory)
        )
        var olderDefinition = ScenarioDefinition.starter()
        olderDefinition.target.projectPath = "/tmp/Old.xcodeproj"
        olderDefinition.target.scheme = "OldScheme"
        olderDefinition.target.destinationIdentifier = "old-device"
        olderDefinition = try olderDefinition.frozen()
        try await persistence.saveDefinition(olderDefinition)
        let coordinator = ScenarioCoordinator(supportDirectory: root, evaluationStore: store)
        await coordinator.load()
        coordinator.configuration.containerPath = "/tmp/Fixture.xcodeproj"
        coordinator.configuration.scheme = "Fixture"
        coordinator.configuration.destinationIdentifier = "physical-device-1"
        coordinator.configuration.testBundleIdentifier = "dev.example.FixtureUITests"
        coordinator.configuration.generatedResourceDirectory = "/tmp/FixtureGenerated"
        coordinator.projectTrusted = true
        await coordinator.refreshPreflight()

        let reloaded = ScenarioCoordinator(supportDirectory: root, evaluationStore: store)
        await reloaded.load()

        #expect(reloaded.configuration.testBundleIdentifier == "dev.example.FixtureUITests")
        #expect(reloaded.configuration.generatedResourceDirectory == "/tmp/FixtureGenerated")
        #expect(reloaded.configuration.containerPath == "/tmp/Fixture.xcodeproj")
        #expect(reloaded.configuration.scheme == "Fixture")
        #expect(reloaded.configuration.destinationIdentifier == "physical-device-1")
        #expect(reloaded.projectTrusted == false)
    }

    @MainActor
    @Test func reusableCheckSelectionKeepsValidAppAndAvoidsAmbiguousFallback() {
        let first = XcodeDiscoveredProduct(
            targetName: "FirstApp", bundleIdentifier: "dev.example.FirstApp",
            productType: "com.apple.product-type.application", isApplication: true,
            isUITestBundle: false, projectPath: "/tmp/Apps.xcodeproj", targetID: "FIRST"
        )
        let second = XcodeDiscoveredProduct(
            targetName: "SecondApp", bundleIdentifier: "dev.example.SecondApp",
            productType: "com.apple.product-type.application", isApplication: true,
            isUITestBundle: false, projectPath: "/tmp/Apps.xcodeproj", targetID: "SECOND"
        )
        let discovery = XcodeConnectionDiscovery(
            schemes: ["Apps"], applications: [first, second], uiTestBundles: []
        )

        #expect(ScenarioCoordinator.selectedReusableApplication(
            in: discovery, selectedProductID: second.id
        )?.id == second.id)
        #expect(ScenarioCoordinator.selectedReusableApplication(
            in: discovery, selectedProductID: "stale-product-id"
        ) == nil)
        #expect(ScenarioCoordinator.selectedReusableApplication(
            in: discovery, selectedProductID: nil
        ) == nil)

        let uniqueDiscovery = XcodeConnectionDiscovery(
            schemes: ["Apps"], applications: [first], uiTestBundles: []
        )
        #expect(ScenarioCoordinator.selectedReusableApplication(
            in: uniqueDiscovery, selectedProductID: "stale-product-id"
        )?.id == first.id)
    }

    @MainActor
    @Test func discoveryPreservesAvailableSavedSchemeBeforeUsingPreferredDefault() {
        let app = XcodeDiscoveredProduct(
            targetName: "IntentLabFixture", bundleIdentifier: "dev.example.Fixture",
            productType: "com.apple.product-type.application", isApplication: true,
            isUITestBundle: false
        )
        let discovery = XcodeConnectionDiscovery(
            schemes: ["IntentLabFixture", "IntentLabFixtureV2"],
            applications: [app], uiTestBundles: []
        )
        #expect(discovery.automaticallySelectedScheme == "IntentLabFixture")
        #expect(ScenarioCoordinator.schemeAfterDiscovery("IntentLabFixtureV2", in: discovery)
            == "IntentLabFixtureV2")
        #expect(ScenarioCoordinator.schemeAfterDiscovery("", in: discovery)
            == "IntentLabFixture")
        #expect(ScenarioCoordinator.schemeAfterDiscovery("RemovedScheme", in: discovery)
            == "IntentLabFixture")
    }

    @MainActor
    @Test func installedIntegrationUsesOnlyMatchingDiscoveredProducts() {
        let app = XcodeDiscoveredProduct(
            targetName: "Fixture", bundleIdentifier: "dev.example.Fixture",
            productType: "com.apple.product-type.application", isApplication: true,
            isUITestBundle: false, projectPath: "/tmp/Fixture.xcodeproj", targetID: "APP",
            signingConfigured: true
        )
        let legacyTests = XcodeDiscoveredProduct(
            targetName: "LegacyUITests", bundleIdentifier: "dev.example.LegacyUITests",
            productType: "com.apple.product-type.bundle.ui-testing", isApplication: false,
            isUITestBundle: true, projectPath: "/tmp/Fixture.xcodeproj", targetID: "OLD"
        )
        let installedTests = XcodeDiscoveredProduct(
            targetName: "IntentLabUITests", bundleIdentifier: "dev.example.IntentLabUITests",
            productType: "com.apple.product-type.bundle.ui-testing", isApplication: false,
            isUITestBundle: true, projectPath: "/tmp/Fixture.xcodeproj", targetID: "NEW",
            harnessVersion: "2", harnessCapabilities: ["direct-intent-execution"], signingConfigured: true
        )
        let discovery = XcodeConnectionDiscovery(
            schemes: ["Fixture"], applications: [app], uiTestBundles: [legacyTests, installedTests]
        )

        let matched = ScenarioCoordinator.installedProducts(
            in: discovery, appBundleID: app.bundleIdentifier, applicationProductID: app.id,
            testTarget: installedTests.targetName, testProductID: installedTests.id
        )
        #expect(matched.application == app)
        #expect(matched.tests == installedTests)
        #expect(ScenarioCoordinator.installedProducts(
            in: discovery, appBundleID: app.bundleIdentifier, applicationProductID: app.id,
            testTarget: installedTests.targetName, testProductID: legacyTests.id
        ).tests == nil)
    }

    @MainActor
    @Test func installedIntegrationClearsLegacyTestMetadataWithoutMatchingDiscovery() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ScenarioCoordinator(
            supportDirectory: root, evaluationStore: EvaluationStore(supportDirectory: root)
        )
        coordinator.configuration.testBundleIdentifier = "dev.example.LegacyUITests"
        coordinator.configuration.harnessVersion = "1"
        coordinator.configuration.harnessCapabilities = ["legacy"]
        coordinator.configuration.testSigningConfigured = true

        coordinator.recordInstalledIntegration(
            .init(id: "dev.example.Fixture.intentlab", version: "1", digest: String(repeating: "a", count: 64)),
            appBundleID: "dev.example.Fixture", projectPath: "/tmp/Fixture.xcodeproj",
            scheme: "Fixture", testTarget: "IntentLabUITests",
            applicationProductID: "/tmp/Fixture.xcodeproj#APP",
            testProductID: "/tmp/Fixture.xcodeproj#NEW"
        )
        #expect(coordinator.configuration.testTarget == "IntentLabUITests")
        #expect(coordinator.configuration.testBundleIdentifier.isEmpty)
        #expect(coordinator.configuration.harnessVersion == nil)
        #expect(coordinator.configuration.harnessCapabilities == nil)
        #expect(coordinator.configuration.testSigningConfigured == nil)
    }

    @MainActor
    @Test func switchingSavedTargetsKeepsAUsableConnectionOrOffersReconnect() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvaluationStore(supportDirectory: root)
        let coordinator = ScenarioCoordinator(
            supportDirectory: root, evaluationStore: store
        )
        let project = "/tmp/Shared.xcodeproj"
        coordinator.configuration.containerPath = project
        coordinator.configuration.scheme = "First"
        coordinator.configuration.testTarget = "FirstUITests"
        coordinator.configuration.destinationIdentifier = "test-device"
        let first = try await coordinator.freezeAndSave()
        coordinator.draft.id = UUID()
        coordinator.draft.name = "Second test"
        coordinator.configuration.scheme = "Second"
        coordinator.configuration.testTarget = "SecondUITests"
        let second = try await coordinator.freezeAndSave()

        let app = XcodeDiscoveredProduct(
            targetName: "Fixture", bundleIdentifier: first.target.bundleIdentifier,
            productType: "com.apple.product-type.application", isApplication: true,
            isUITestBundle: false, projectPath: project, targetID: "APP", signingConfigured: true
        )
        let firstTests = XcodeDiscoveredProduct(
            targetName: "FirstUITests", bundleIdentifier: "dev.example.FirstUITests",
            productType: "com.apple.product-type.bundle.ui-testing", isApplication: false,
            isUITestBundle: true, projectPath: project, targetID: "FIRST", signingConfigured: true
        )
        let secondTests = XcodeDiscoveredProduct(
            targetName: "SecondUITests", bundleIdentifier: "dev.example.SecondUITests",
            productType: "com.apple.product-type.bundle.ui-testing", isApplication: false,
            isUITestBundle: true, projectPath: project, targetID: "SECOND", signingConfigured: true
        )
        let connected = ScenarioCoordinator(
            supportDirectory: root, evaluationStore: store,
            initialConnectionDiscovery: .init(
                schemes: ["First", "Second"], applications: [app],
                uiTestBundles: [firstTests, secondTests]
            )
        )
        await connected.load()
        connected.projectTrusted = true
        await connected.selectSavedDefinition(id: first.id, version: first.version)
        #expect(connected.projectTrusted)
        #expect(connected.configuration.selectedApplicationProductID == app.id)
        #expect(connected.configuration.selectedTestProductID == firstTests.id)
        #expect(connected.draft.definitionDigest == first.definitionDigest)

        let missing = ScenarioCoordinator(
            supportDirectory: root, evaluationStore: store,
            initialConnectionDiscovery: .init(
                schemes: ["First", "Second"], applications: [app],
                uiTestBundles: [firstTests]
            )
        )
        await missing.load()
        missing.projectTrusted = true
        await missing.selectSavedDefinition(id: first.id, version: first.version)
        #expect(missing.projectTrusted)
        await missing.selectSavedDefinition(id: second.id, version: second.version)
        #expect(!missing.projectTrusted)
        #expect(missing.configuration.selectedTestProductID == nil)
        #expect(missing.notice?.contains("Connect this project again") == true)
    }

    @MainActor
    @Test func deviceDiscoverySelectsOnlyOneAvailableDestinationWithoutSavedChoice() {
        let phone = IntentLabDeviceDestination(
            identifier: "phone-1", name: "iPhone", operatingSystemVersion: "27.0",
            available: true, platform: .iOS
        )
        let unavailableMac = IntentLabDeviceDestination(
            identifier: "mac-1", name: "Mac", operatingSystemVersion: "27.0",
            available: false, platform: .macOS
        )
        let availableMac = IntentLabDeviceDestination(
            identifier: "mac-2", name: "Mac", operatingSystemVersion: "27.0",
            available: true, platform: .macOS
        )

        #expect(ScenarioCoordinator.soleAvailableDestinationIdentifier(
            in: [phone, unavailableMac], savedDestinationIdentifier: ""
        ) == phone.identifier)
        #expect(ScenarioCoordinator.soleAvailableDestinationIdentifier(
            in: [phone, availableMac], savedDestinationIdentifier: ""
        ) == nil)
        #expect(ScenarioCoordinator.soleAvailableDestinationIdentifier(
            in: [phone], savedDestinationIdentifier: "previously-saved-device"
        ) == nil)
        #expect(ScenarioCoordinator.soleAvailableDestinationIdentifier(
            in: [phone], savedDestinationIdentifier: phone.identifier
        ) == nil)
    }

    @MainActor
    @Test func savedTestSwitchRestoresTargetAndClearsStaleConnection() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvaluationStore(supportDirectory: root)
        let coordinator = ScenarioCoordinator(supportDirectory: root, evaluationStore: store)
        coordinator.configuration.containerPath = "/tmp/First.xcodeproj"
        coordinator.configuration.destinationIdentifier = "first-device"
        let first = try await coordinator.freezeAndSave()
        coordinator.draft.id = UUID()
        coordinator.draft.name = "Second test"
        coordinator.configuration.containerPath = "/tmp/Second.xcodeproj"
        coordinator.configuration.destinationIdentifier = "second-device"
        let second = try await coordinator.freezeAndSave()
        coordinator.projectTrusted = true
        coordinator.configuration.selectedApplicationProductID = "stale-app"
        coordinator.configuration.selectedTestProductID = "stale-tests"
        coordinator.configuration.applicationSigningConfigured = true
        coordinator.parameterArrayDraftTexts = [0: "1,"]
        coordinator.invalidParameterDraftIndices = [0]
        coordinator.selectedRunID = UUID()

        await coordinator.selectSavedDefinition(id: first.id, version: first.version)
        #expect(coordinator.draft == first)
        #expect(coordinator.configuration.containerPath == first.target.projectPath)
        #expect(coordinator.configuration.destinationIdentifier == "first-device")
        #expect(!coordinator.projectTrusted)
        #expect(coordinator.configuration.selectedApplicationProductID == nil)
        #expect(coordinator.configuration.selectedTestProductID == nil)
        #expect(coordinator.configuration.applicationSigningConfigured == nil)
        #expect(coordinator.parameterArrayDraftTexts.isEmpty)
        #expect(coordinator.invalidParameterDraftIndices.isEmpty)
        #expect(coordinator.selectedRunID == nil)
        #expect(coordinator.preflight == nil)
        #expect(coordinator.verifiedIntegrationSummary == nil)

        await coordinator.selectSavedDefinition(id: second.id, version: second.version)
        #expect(coordinator.draft == second)
        #expect(coordinator.configuration.destinationIdentifier == "second-device")
        let persistence = ScenarioPersistence(rootDirectory: root.appending(path: "IntentLab"))
        let selected = try await persistence.loadSelectedDefinition()
        #expect(selected?.id == second.id)
        #expect(selected?.version == second.version)

        coordinator.projectTrusted = true
        await coordinator.selectSavedDefinition(id: second.id, version: second.version)
        #expect(coordinator.projectTrusted, "The same project keeps its session approval")
        #expect(coordinator.preflight != nil, "Switching within an approved project refreshes readiness")
        await coordinator.selectSavedDefinition(id: UUID(), version: 1)
        #expect(coordinator.draft == second, "An unknown saved test cannot replace the current draft")
    }

    @MainActor
    @Test func reloadingRenamedScenarioSelectsLatestVersionOfLastRunScenario() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvaluationStore(supportDirectory: root)
        let persistence = ScenarioPersistence(
            rootDirectory: store.overviewStorageDirectory.appending(path: "IntentLab", directoryHint: .isDirectory)
        )
        var original = ScenarioDefinition.starter()
        original.name = "Open the packing note"
        original.target.destinationIdentifier = "physical-device-1"
        original = try original.frozen()
        var renamed = original
        renamed.version = 2
        renamed.name = "Negative control — wrong expected note"
        renamed = try renamed.frozen()
        try await persistence.saveDefinition(original)
        try await persistence.saveDefinition(renamed)

        let withoutRun = ScenarioCoordinator(supportDirectory: root, evaluationStore: store)
        await withoutRun.load()
        #expect(withoutRun.draft.id == renamed.id)
        #expect(withoutRun.draft.version == renamed.version)

        var unrelated = ScenarioDefinition.starter()
        unrelated.name = "Zulu unrelated scenario"
        unrelated.target.destinationIdentifier = "physical-device-1"
        unrelated = try unrelated.frozen()
        try await persistence.saveDefinition(unrelated)
        let now = Date()
        let invocation = ScenarioInvocationIdentity(
            id: UUID(), nonce: UUID().uuidString, issuedAt: now,
            testIdentity: .init(bundleIdentifier: "dev.example.FixtureUITests",
                                className: "IntentLabScenarioTests", methodName: "testIntentLabScenario"),
            harnessVersion: ScenarioInvocationIdentity.currentHarnessVersion,
            destinationIdentifier: "physical-device-1", scenarioDigest: renamed.definitionDigest,
            resultBundleIdentity: "IntentLab.xcresult"
        )
        let failedIntent = ScenarioLaneResult(
            caseID: renamed.id, attempt: 1, lane: .intentIntegration,
            executionStatus: .completed, outcome: .failed,
            startedAt: now, completedAt: now
        )
        let failedSiri = (1...(renamed.coverage.siriAttemptCount ?? 3)).map { attempt in
            ScenarioLaneResult(
                caseID: renamed.id, attempt: attempt, lane: .siri,
                executionStatus: .completed, outcome: .failed,
                startedAt: now, completedAt: now
            )
        }
        let run = ScenarioRun(
            id: invocation.id, scenarioID: renamed.id, scenarioVersion: renamed.version,
            scenarioDigest: renamed.definitionDigest, invocation: invocation,
            startedAt: now, completedAt: now,
            environment: .init(xcodeVersion: "27", sdkVersion: "27", deviceModel: "iPhone",
                               operatingSystem: "iOS 27", languageCode: "en", regionCode: "GB",
                               timeZoneIdentifier: "Europe/London", executedAt: now),
            executionStatus: .completed, outcome: .failed, laneResults: [failedIntent] + failedSiri,
            linkedFeatureRunID: nil, importedAt: now
        )
        _ = try await persistence.saveRun(run, artifactRoot: nil)

        let reloaded = ScenarioCoordinator(supportDirectory: root, evaluationStore: store)
        await reloaded.load()
        #expect(reloaded.selectedRunID == run.id)
        #expect(reloaded.draft.id == renamed.id)
        #expect(reloaded.draft.version == renamed.version)
        #expect(reloaded.draft.name == renamed.name)
    }

    @MainActor
    @Test func failedOrUnobservedFinalEvidenceKeepsDeviceQuarantined() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ScenarioPersistence(rootDirectory: root)
        let executor = XcodeTestExecutor(workDirectory: root.appending(path: "Executor"), persistence: persistence)
        var definition = ScenarioDefinition.starter()
        definition = try definition.frozen()
        let now = Date()
        let invocation = ScenarioInvocationIdentity(
            id: UUID(), nonce: UUID().uuidString, issuedAt: now,
            testIdentity: .init(bundleIdentifier: "dev.example.FixtureUITests",
                                className: "IntentLabScenarioTests", methodName: "testIntentLabScenario"),
            harnessVersion: ScenarioInvocationIdentity.currentHarnessVersion,
            destinationIdentifier: "physical-device-1", scenarioDigest: definition.definitionDigest,
            resultBundleIdentity: "IntentLab.xcresult"
        )
        let journal = ScenarioExecutionJournal(
            phase: .stopped, invocation: invocation, scenarioID: definition.id,
            scenarioVersion: definition.version, resultBundlePath: "", derivedDataPath: "",
            buildLogPath: "", intendedExecutable: "", intendedArguments: [],
            processIdentifier: nil, processStartedAt: nil, updatedAt: now, recoveryReason: nil
        )
        let siri = ScenarioLaneResult(
            caseID: definition.id, attempt: 1, lane: .siri,
            executionStatus: .timedOut, outcome: .notObserved,
            startedAt: now, completedAt: now, observations: [:], assertionResults: []
        )
        let run = ScenarioRun(
            id: invocation.id, scenarioID: definition.id, scenarioVersion: definition.version,
            scenarioDigest: definition.definitionDigest, invocation: invocation,
            startedAt: now, completedAt: now,
            environment: .init(xcodeVersion: "27", sdkVersion: "27", deviceModel: "iPhone",
                               operatingSystem: "iOS 27", languageCode: "en", regionCode: "GB",
                               timeZoneIdentifier: "Europe/London", executedAt: now),
            executionStatus: .timedOut, outcome: .notObserved, laneResults: [siri],
            linkedFeatureRunID: nil, importedAt: now
        )
        let final = ScenarioEvidenceAttachment(url: root.appending(path: "final.json"), name: "IntentLabEvidence-final")
        #expect(!ScenarioCoordinator.canReleaseDevice(
            processExitCode: 1, attachments: [final], importedRuns: [run]
        ))
        #expect(!ScenarioCoordinator.canReleaseDevice(
            processExitCode: 0, attachments: [final], importedRuns: [run]
        ))
        var complete = run
        complete.executionStatus = .completed
        complete.outcome = .passed
        complete.xctestExitCode = 0
        complete.laneResults[0].executionStatus = .completed
        complete.laneResults[0].outcome = .passed
        #expect(ScenarioCoordinator.canReleaseDevice(
            processExitCode: 0, attachments: [final], importedRuns: [complete]
        ))
        let cancelled = try #require(ScenarioCoordinator.evidenceForCommit([complete], cancelled: true).first)
        #expect(cancelled.executionStatus == .invalidEvidence)
        #expect(cancelled.outcome == .needsReview)
        #expect(!ScenarioCoordinator.canReleaseDevice(
            processExitCode: 0, attachments: [final], importedRuns: [cancelled]
        ))
        try await executor.finishEvidenceValidation(journal: journal, accepted: false)
        #expect(await executor.reservation(for: invocation.destinationIdentifier) != nil)
    }

    @Test func cancellationBetweenBuildAndTestStopsNextProcessBeforeLaunch() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ScenarioPersistence(rootDirectory: root)
        let executor = XcodeTestExecutor(workDirectory: root.appending(path: "Executor"), persistence: persistence)
        let definition = try ScenarioDefinition.starter().frozen()
        let invocation = ScenarioInvocationIdentity(
            id: UUID(), nonce: UUID().uuidString, issuedAt: Date(),
            testIdentity: .init(bundleIdentifier: "dev.example.FixtureUITests",
                                className: "IntentLabScenarioTests", methodName: "testIntentLabScenario"),
            harnessVersion: ScenarioInvocationIdentity.currentHarnessVersion,
            destinationIdentifier: "physical-device-1", scenarioDigest: definition.definitionDigest,
            resultBundleIdentity: "IntentLab.xcresult"
        )
        let journal = ScenarioExecutionJournal(
            phase: .preparing, invocation: invocation, scenarioID: definition.id,
            scenarioVersion: definition.version, resultBundlePath: "", derivedDataPath: "",
            buildLogPath: "", intendedExecutable: "/bin/sh", intendedArguments: [],
            processIdentifier: nil, processStartedAt: nil, updatedAt: Date(), recoveryReason: nil
        )
        try await executor.persistPreparingJournal(journal)
        let cancelled = await executor.cancelActiveExecution(grace: .milliseconds(10))
        #expect(cancelled?.phase == .recoveryRequired)
        let marker = root.appending(path: "launched")
        do {
            _ = try await executor.runProcess(
                executable: "/bin/sh", arguments: ["-c", "touch \(marker.path)"],
                logURL: root.appending(path: "process.log"), invocationID: invocation.id,
                destinationIdentifier: invocation.destinationIdentifier, journal: journal,
                appendLog: false
            )
            Issue.record("A cancelled invocation launched another process.")
        } catch XcodeTestExecutorError.cancelled {
            // The cancellation is expected before process launch.
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(await executor.reservation(for: invocation.destinationIdentifier) != nil)
    }

    @Test func journalWriteFailureStopsLaunchedProcess() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ScenarioPersistence(rootDirectory: root)
        let executor = XcodeTestExecutor(workDirectory: root.appending(path: "Executor"), persistence: persistence)
        let definition = try ScenarioDefinition.starter().frozen()
        let invocation = ScenarioInvocationIdentity(
            id: UUID(), nonce: UUID().uuidString, issuedAt: Date(),
            testIdentity: .init(bundleIdentifier: "dev.example.FixtureUITests",
                                className: "IntentLabScenarioTests", methodName: "testIntentLabScenario"),
            harnessVersion: ScenarioInvocationIdentity.currentHarnessVersion,
            destinationIdentifier: "physical-device-1", scenarioDigest: definition.definitionDigest,
            resultBundleIdentity: "IntentLab.xcresult"
        )
        let journal = ScenarioExecutionJournal(
            phase: .preparing, invocation: invocation, scenarioID: definition.id,
            scenarioVersion: definition.version, resultBundlePath: "", derivedDataPath: "",
            buildLogPath: "", intendedExecutable: "/bin/sh", intendedArguments: [],
            processIdentifier: nil, processStartedAt: nil, updatedAt: Date(), recoveryReason: nil
        )
        let blockedJournal = root.appending(path: "Journals/\(invocation.id.uuidString).json", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: blockedJournal, withIntermediateDirectories: true)
        let launchedProcess = ProcessIDRecorder()
        do {
            _ = try await executor.runProcess(
                executable: "/bin/sleep", arguments: ["10"],
                logURL: root.appending(path: "process.log"), invocationID: invocation.id,
                destinationIdentifier: invocation.destinationIdentifier, journal: journal,
                appendLog: false,
                onProcessLaunched: { launchedProcess.record($0) }
            )
            Issue.record("The blocked journal unexpectedly saved.")
        } catch {
            let processID = try #require(launchedProcess.value)
            let processCheck = kill(processID, 0)
            let processError = errno
            #expect(processCheck == -1)
            #expect(processError == ESRCH)
            #expect(!(await executor.hasActiveExecution()))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "IntentLabRegressionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private final class ProcessIDRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue: Int32?

        var value: Int32? {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }

        func record(_ processID: Int32) {
            lock.lock()
            defer { lock.unlock() }
            storedValue = processID
        }
    }

    private func deadlineDefinition(
        directLane: Bool,
        siriLane: Bool,
        siriAttemptCount: Int,
        deadlineSeconds: Double
    ) -> ScenarioDefinition {
        var definition = ScenarioDefinition.starter()
        definition.coverage.intentIntegration = directLane ? .required : .notApplicable
        definition.coverage.siri = siriLane ? .required : .notApplicable
        definition.coverage.siriAttemptCount = siriAttemptCount
        definition.safety.deadlineSeconds = deadlineSeconds
        return definition
    }

    private func collectionDefinition(projectID: UUID, name: String) throws -> ScenarioDefinition {
        var definition = ScenarioDefinition.starter(projectID: projectID)
        definition.id = UUID()
        definition.name = name
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.coverage = .init(appFeature: .notApplicable, intentIntegration: .required,
                                    siri: .notApplicable, siriAttemptCount: nil)
        definition.purpose = .exploratory
        definition.checkMode = .basic
        definition.requiredClaims = [.executionCompleted, .returnedValueChecked]
        definition.integration = .init(
            id: "notes", version: "1", digest: String(repeating: "a", count: 64)
        )
        definition.directControl.outputFields = [.init(
            name: "selectedNoteID", type: .primitive(.string),
            path: [.init(kind: .property, name: "selectedNoteID")]
        )]
        definition.observationPlan = [.init(id: "selectedNoteID", source: .intentResult)]
        definition.assertions = [.init(
            kind: .returnedField, observationKey: "selectedNoteID",
            expectedValue: .string("packing-001"),
            explanation: "The returned note is the requested note.",
            applicableLanes: [.intentIntegration]
        )]
        return try definition.frozen()
    }
}
