import Foundation
import Testing
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

    @Test func siriCoverageRequiresPhysicalIPhoneButDirectChecksAllowMac() {
        let mac = IntentLabDeviceDestination(
            identifier: "mac-1", name: "Mac", operatingSystemVersion: "27.0",
            available: true, platform: .macOS
        )
        let phone = IntentLabDeviceDestination(
            identifier: "phone-1", name: "iPhone", operatingSystemVersion: "27.0",
            available: true, platform: .iOS
        )
        let devices = [mac, phone]

        #expect(XcodeTestExecutor.destinationStatus(identifier: mac.identifier, devices: devices).ready)
        let rejected = XcodeTestExecutor.destinationStatus(
            identifier: mac.identifier, devices: devices, requiresSiri: true
        )
        #expect(!rejected.ready)
        #expect(rejected.detail.contains("physical iPhone"))
        #expect(XcodeTestExecutor.destinationStatus(
            identifier: phone.identifier, devices: devices, requiresSiri: true
        ).ready)
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

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "IntentLabRegressionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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
}
