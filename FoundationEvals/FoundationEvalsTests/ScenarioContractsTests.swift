import CryptoKit
import Foundation
import Testing
@testable import FoundationEvals

struct ScenarioContractsTests {
    @Test func xctestrunTransportKeepsTestRootAndPreservesXcodeEnvironment() throws {
        let root = try temporaryDirectory()
        let products = root.appending(path: "DerivedData/Build/Products", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        let source = products.appending(path: "Fixture_iphoneos.xctestrun")
        let plist: [String: Any] = [
            "__xctestrun_metadata__": ["FormatVersion": 1],
            "FixtureUITests": [
                "BlueprintName": "FixtureUITests",
                "ProductModuleName": "FixtureUITests",
                "UITargetAppPath": "__TESTROOT__/Debug-iphoneos/Fixture.app",
                "TestHostPath": "__TESTROOT__/Debug-iphoneos/FixtureUITests-Runner.app",
                "TestBundlePath": "__TESTHOST__/PlugIns/FixtureUITests.xctest",
                "EnvironmentVariables": ["XCODE_OWNED": "preserved"],
                "TestingEnvironmentVariables": ["XCODE_SCHEME_NAME": "Fixture"],
            ],
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: source)
        let paths = try XCTestRunInvocationTransport.resolveProducts(
            derivedData: root.appending(path: "DerivedData"),
            testTarget: "FixtureUITests"
        )
        #expect(paths.sourceURL.standardizedFileURL == source.standardizedFileURL)
        #expect(paths.appBundleURL.path.hasSuffix("Debug-iphoneos/Fixture.app"))
        #expect(paths.testBundleURL.path.hasSuffix("FixtureUITests-Runner.app/PlugIns/FixtureUITests.xctest"))

        let definition = try scenario()
        let boundInvocation = invocation(for: definition)
        let output = try XCTestRunInvocationTransport.materialize(
            products: paths,
            testTarget: "FixtureUITests",
            definition: definition,
            invocation: boundInvocation
        )
        #expect(
            output.deletingLastPathComponent().standardizedFileURL
                == source.deletingLastPathComponent().standardizedFileURL
        )
        let stored = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: output), options: [], format: nil
        ) as? [String: Any])
        let target = try #require(stored["FixtureUITests"] as? [String: Any])
        let environment = try #require(target["EnvironmentVariables"] as? [String: String])
        #expect(environment["XCODE_OWNED"] == "preserved")
        #expect(environment[XCTestRunInvocationTransport.scenarioEnvironmentKey] != nil)
        #expect(environment[XCTestRunInvocationTransport.invocationEnvironmentKey] != nil)
        #expect((target["TestingEnvironmentVariables"] as? [String: String])?["XCODE_SCHEME_NAME"] == "Fixture")
    }

    @Test func xctestrunTransportSupportsVersionTwoAndRejectsOversizedPayload() throws {
        let root = try temporaryDirectory()
        let products = root.appending(path: "DerivedData/Build/Products", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        let source = products.appending(path: "Fixture_iphoneos.xctestrun")
        let target: [String: Any] = [
            "BlueprintName": "FixtureUITests",
            "UITargetAppPath": "__TESTROOT__/Debug-iphoneos/Fixture.app",
            "TestHostPath": "__TESTROOT__/Debug-iphoneos/FixtureUITests-Runner.app",
            "TestBundlePath": "__TESTHOST__/PlugIns/FixtureUITests.xctest",
        ]
        let plist: [String: Any] = [
            "__xctestrun_metadata__": ["FormatVersion": 2],
            "TestConfigurations": [["Name": "Test Scheme Action", "TestTargets": [target]]],
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: source)
        let paths = try XCTestRunInvocationTransport.resolveProducts(
            derivedData: root.appending(path: "DerivedData"),
            testTarget: "FixtureUITests"
        )
        var definition = try scenario()
        definition.goal.expectedBehavior = String(repeating: "x", count: XCTestRunInvocationTransport.maximumPayloadBytes)

        #expect(throws: XCTestRunInvocationTransportError.self) {
            _ = try XCTestRunInvocationTransport.materialize(
                products: paths,
                testTarget: "FixtureUITests",
                definition: definition,
                invocation: invocation(for: definition)
            )
        }
    }

    @Test func workspaceDuplicateTestNamesBindOwningProjectInTestRun() throws {
        let root = try temporaryDirectory()
        let workspace = root.appending(path: "Combined.xcworkspace", directoryHint: .isDirectory)
        let firstProject = root.appending(path: "First/Shared.xcodeproj", directoryHint: .isDirectory)
        let secondProject = root.appending(path: "Second/Shared.xcodeproj", directoryHint: .isDirectory)
        for directory in [workspace, firstProject, secondProject] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let products = root.appending(path: "DerivedData/Build/Products", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        let source = products.appending(path: "Combined_iphoneos.xctestrun")
        func target(owner: String, runner: String) -> [String: Any] {
            ["BlueprintName": "SharedUITests", "BlueprintProviderRelativePath": owner,
             "ProductModuleName": "SharedUITests",
             "UITargetAppPath": "__TESTROOT__/Debug-iphoneos/Shared.app",
             "TestHostPath": "__TESTROOT__/Debug-iphoneos/\(runner).app",
             "TestBundlePath": "__TESTHOST__/PlugIns/SharedUITests.xctest"]
        }
        let plist: [String: Any] = [
            "__xctestrun_metadata__": ["FormatVersion": 2],
            "TestConfigurations": [["Name": "Combined", "TestTargets": [
                target(owner: "First/Shared.xcodeproj", runner: "FirstRunner"),
                target(owner: "Second/Shared.xcodeproj", runner: "SecondRunner"),
            ]]],
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: source)
        #expect(throws: XCTestRunInvocationTransportError.self) {
            _ = try XCTestRunInvocationTransport.resolveProducts(
                derivedData: root.appending(path: "DerivedData"), testTarget: "SharedUITests"
            )
        }
        let paths = try XCTestRunInvocationTransport.resolveProducts(
            derivedData: root.appending(path: "DerivedData"), testTarget: "SharedUITests",
            owningProjectURL: secondProject, containerURL: workspace
        )
        #expect(paths.testHostURL.lastPathComponent == "SecondRunner.app")
        let definition = try scenario()
        let output = try XCTestRunInvocationTransport.materialize(
            products: paths, testTarget: "SharedUITests",
            definition: definition, invocation: invocation(for: definition)
        )
        let stored = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: output), options: [], format: nil
        ) as? [String: Any])
        let configurations = try #require(stored["TestConfigurations"] as? [[String: Any]])
        let targets = try #require(configurations[0]["TestTargets"] as? [[String: Any]])
        #expect(targets[0]["EnvironmentVariables"] == nil)
        let selectedEnvironment = targets[1]["EnvironmentVariables"] as? [String: String]
        #expect(selectedEnvironment?[XCTestRunInvocationTransport.invocationEnvironmentKey] != nil)
        #expect(throws: XCTestRunInvocationTransportError.self) {
            _ = try XCTestRunInvocationTransport.resolveProducts(
                derivedData: root.appending(path: "DerivedData"), testTarget: "SharedUITests",
                owningProjectURL: root.appending(path: "Other.xcodeproj"), containerURL: workspace
            )
        }

        let scheme = workspace.appending(path: "xcshareddata/xcschemes/Combined.xcscheme")
        try FileManager.default.createDirectory(at: scheme.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        <Scheme><TestAction><Testables><TestableReference><BuildableReference
        BlueprintIdentifier="SECOND-ID" BlueprintName="SharedUITests"
        ReferencedContainer="container:Second/Shared.xcodeproj"/>
        </TestableReference></Testables></TestAction></Scheme>
        """.utf8).write(to: scheme)
        let configuration = XcodeTestConfiguration(
            containerPath: workspace.path, isWorkspace: true, scheme: "Combined",
            testTarget: "SharedUITests", testBundleIdentifier: "dev.example.SharedUITests",
            destinationIdentifier: "device", generatedResourceDirectory: root.path
        )
        let selected = XcodeDiscoveredProduct(
            targetName: "SharedUITests", bundleIdentifier: "dev.example.SharedUITests",
            productType: "com.apple.product-type.bundle.ui-testing", isApplication: false,
            isUITestBundle: true, projectPath: secondProject.path, targetID: "SECOND-ID"
        )
        #expect(XcodeTestExecutor.selectedSchemeContainsTarget(configuration: configuration, product: selected))
        var wrong = selected
        wrong.targetID = "FIRST-ID"
        #expect(!XcodeTestExecutor.selectedSchemeContainsTarget(configuration: configuration, product: wrong))
    }

    @Test func quickConnectDiscoveryParsesProjectsProductsAndPhysicalIPhones() throws {
        let listing = Data("""
        {"project":{"name":"Fixture","targets":["Fixture","FixtureUITests"],"schemes":["Fixture"]}}
        """.utf8)
        let parsedListing = try XcodeConnectionDiscoveryService.parseListing(listing)
        #expect(parsedListing.schemes == ["Fixture"])
        #expect(parsedListing.targets == ["Fixture", "FixtureUITests"])

        let settings = Data("""
        [
          {"target":"Fixture","buildSettings":{"PRODUCT_BUNDLE_IDENTIFIER":"dev.example.Fixture","PRODUCT_TYPE":"com.apple.product-type.application","WRAPPER_EXTENSION":"app"}},
          {"target":"FixtureTests","buildSettings":{"PRODUCT_BUNDLE_IDENTIFIER":"dev.example.FixtureTests","PRODUCT_TYPE":"com.apple.product-type.bundle.unit-test","WRAPPER_EXTENSION":"xctest","TEST_HOST":"Fixture.app/Fixture"}},
          {"target":"FixtureUITests","buildSettings":{"PRODUCT_BUNDLE_IDENTIFIER":"dev.example.FixtureUITests","PRODUCT_TYPE":"com.apple.product-type.bundle.ui-testing","WRAPPER_EXTENSION":"xctest","DEVELOPMENT_TEAM":"TEAM123","INTENT_LAB_HARNESS_VERSION":"intent-lab-v1","INTENT_LAB_HARNESS_CAPABILITIES":"environment-payload fixture-reset invocation-correlation accessible-result direct-intent-output"}}
        ]
        """.utf8)
        let products = try XcodeConnectionDiscoveryService.parseBuildSettings(settings)
        #expect(products.first(where: \.isApplication)?.bundleIdentifier == "dev.example.Fixture")
        #expect(products.first(where: \.isUITestBundle)?.targetName == "FixtureUITests")
        #expect(!products.contains { $0.targetName == "FixtureTests" })
        #expect(products.first(where: \.isUITestBundle)?.harnessVersion == "intent-lab-v1")
        #expect(products.first(where: \.isUITestBundle)?.harnessCapabilities.contains("fixture-reset") == true)
        #expect(products.first(where: \.isUITestBundle)?.signingConfigured == true)

        let workspace = try temporaryDirectory().appending(path: "Fixture.xcworkspace", directoryHint: .isDirectory)
        let group = workspace.deletingLastPathComponent().appending(path: "Apps & Tools", directoryHint: .isDirectory)
        let project = group.appending(path: "Fixture.xcodeproj", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace version="1.0"><Group location="group:Apps &amp; Tools"><FileRef location="group:Fixture.xcodeproj"></FileRef></Group></Workspace>
        """.utf8).write(to: workspace.appending(path: "contents.xcworkspacedata"))
        #expect(try XcodeConnectionDiscoveryService.workspaceProjectURLs(workspace: workspace) == [project])

        let devices = Data("""
        [
          {"identifier":"phone-1","name":"Cory's iPhone","platform":"com.apple.platform.iphoneos","simulator":false,"available":true,"ignored":false,"operatingSystemVersion":"27.0"},
          {"identifier":"sim-1","name":"Simulator","platform":"com.apple.platform.iphonesimulator","simulator":true,"available":true}
        ]
        """.utf8)
        let physical = try XcodeConnectionDiscoveryService.parseDevices(devices)
        #expect(physical == [.init(
            identifier: "phone-1", name: "Cory's iPhone",
            operatingSystemVersion: "27.0", available: true
        )])
    }

    @Test func schemeTestActionConfigurationUsesSelectedOwnerAndPreservesDebug() throws {
        let repository = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tasks = repository.appending(path: "examples/IntentLabTasks/IntentLabTasks.xcodeproj")
        let notes = repository.appending(path: "examples/IntentLabFixture/IntentLabFixture.xcodeproj")
        #expect(try XcodeConnectionDiscoveryService.testActionBuildConfiguration(
            container: tasks, scheme: "IntentLabTasks"
        ) == "IntentLabTesting")
        #expect(try XcodeConnectionDiscoveryService.testActionBuildConfiguration(
            container: notes, scheme: "IntentLabFixtureV2"
        ) == "Debug")

        let root = try temporaryDirectory()
        let workspace = root.appending(path: "Combined.xcworkspace", directoryHint: .isDirectory)
        let first = root.appending(path: "First/App.xcodeproj", directoryHint: .isDirectory)
        let second = root.appending(path: "Second/App.xcodeproj", directoryHint: .isDirectory)
        for directory in [workspace, first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("""
        <Workspace version="1.0">
          <FileRef location="group:First/App.xcodeproj"/>
          <FileRef location="group:Second/App.xcodeproj"/>
        </Workspace>
        """.utf8).write(to: workspace.appending(path: "contents.xcworkspacedata"))
        for (project, value) in [(first, "Debug"), (second, "IntentLabTesting")] {
            let scheme = project.appending(path: "xcshareddata/xcschemes/Combined.xcscheme")
            try FileManager.default.createDirectory(at: scheme.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("<Scheme><TestAction buildConfiguration=\"\(value)\"/></Scheme>".utf8).write(to: scheme)
        }
        #expect(throws: XcodeConnectionDiscoveryError.self) {
            _ = try XcodeConnectionDiscoveryService.testActionBuildConfiguration(
                container: workspace, scheme: "Combined"
            )
        }
        #expect(try XcodeConnectionDiscoveryService.testActionBuildConfiguration(
            container: workspace, scheme: "Combined", preferredProjectPath: second.path
        ) == "IntentLabTesting")
    }

    @Test func legacyExecutionConfigurationDecodesWithoutManualOverride() throws {
        let bytes = Data("""
        {
          "containerPath": "/tmp/Legacy.xcodeproj",
          "isWorkspace": false,
          "scheme": "Legacy",
          "testTarget": "LegacyUITests",
          "testBundleIdentifier": "dev.example.LegacyUITests",
          "destinationIdentifier": "device",
          "generatedResourceDirectory": "",
          "configuration": "Debug",
          "xcodebuildPath": "/usr/bin/xcodebuild",
          "xcresulttoolPath": "/usr/bin/xcrun"
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(XcodeTestConfiguration.self, from: bytes)
        #expect(decoded.configuration == "Debug")
        #expect(decoded.configurationOverride == nil)
        #expect(decoded.developmentTeam == nil)
        #expect(decoded.allowProvisioningUpdates == nil)
    }

    @Test func developmentSigningOverridesRoundTripAndReachBuildCommands() throws {
        var configuration = XcodeTestConfiguration(
            containerPath: "/tmp/Fixture.xcodeproj", isWorkspace: false, scheme: "Fixture",
            testTarget: "FixtureUITests", testBundleIdentifier: "dev.example.FixtureUITests",
            destinationIdentifier: "device", generatedResourceDirectory: ""
        )
        #expect(configuration.signingArguments.isEmpty)
        configuration.developmentTeam = " TEAM123 "
        configuration.allowProvisioningUpdates = true
        let decoded = try JSONDecoder().decode(
            XcodeTestConfiguration.self, from: JSONEncoder().encode(configuration)
        )
        #expect(decoded.developmentTeam == " TEAM123 ")
        #expect(decoded.allowProvisioningUpdates == true)
        #expect(decoded.signingArguments == ["-allowProvisioningUpdates", "DEVELOPMENT_TEAM=TEAM123"])
        let command = XcodeTestExecutor.xcodeArguments(
            configuration: decoded, derivedData: URL(filePath: "/tmp/DerivedData")
        ) + ["build-for-testing"]
        #expect(command.suffix(3) == ["-allowProvisioningUpdates", "DEVELOPMENT_TEAM=TEAM123", "build-for-testing"])
        configuration.allowProvisioningUpdates = false
        #expect(configuration.signingArguments == ["DEVELOPMENT_TEAM=TEAM123"])
    }

    @Test func discoveryBuildSettingsUsesDevelopmentSigningOverride() throws {
        let arguments = XcodeConnectionDiscoveryService.buildSettingsArguments(
            selector: "-project", container: URL(filePath: "/tmp/Fixture.xcodeproj"),
            targetOrScheme: ["-target", "FixtureUITests"], configuration: "Debug",
            signingArguments: ["-allowProvisioningUpdates", "DEVELOPMENT_TEAM=TEAM123"]
        )
        #expect(arguments == [
            "-project", "/tmp/Fixture.xcodeproj", "-target", "FixtureUITests",
            "-configuration", "Debug", "-showBuildSettings", "-json",
            "-allowProvisioningUpdates", "DEVELOPMENT_TEAM=TEAM123"
        ])
        let settings = Data("""
        [{"target":"FixtureUITests","buildSettings":{
          "PRODUCT_BUNDLE_IDENTIFIER":"dev.example.FixtureUITests",
          "PRODUCT_TYPE":"com.apple.product-type.bundle.ui-testing",
          "DEVELOPMENT_TEAM":"TEAM123"
        }}]
        """.utf8)
        #expect(try XcodeConnectionDiscoveryService.parseBuildSettings(settings).first?.signingConfigured == true)
    }

    @Test func frozenDefinitionRoundTripsWithStableDigest() throws {
        let definition = try scenario()
        let data = try encoder.encode(definition)
        let decoded = try decoder.decode(ScenarioDefinition.self, from: data)

        #expect(decoded == definition)
        #expect(decoded.hasValidDigest)
        #expect(try decoded.calculatedDigest() == definition.definitionDigest)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("requiredClaims"))
        #expect(!json.contains("observationPlan"))
    }

    @Test func selectedDefinitionPersistsByIdentityAcrossRelaunch() async throws {
        let root = try temporaryDirectory()
        let persistence = ScenarioPersistence(rootDirectory: root)
        var alpha = try scenario()
        alpha.name = "Alpha"
        alpha = try alpha.frozen()
        var zeta = try scenario()
        zeta.name = "Zeta"
        zeta = try zeta.frozen()
        try await persistence.saveDefinition(alpha)
        try await persistence.saveDefinition(zeta)
        try await persistence.saveSelectedDefinition(id: alpha.id, version: alpha.version)
        let reloaded = ScenarioPersistence(rootDirectory: root)
        #expect(try await reloaded.loadSelectedDefinition() == .init(id: alpha.id, version: alpha.version))
        #expect(try await reloaded.loadDefinitions().last?.id == zeta.id)
    }

    @Test func archivedVersionOneFilesKeepTheirDigestAndImportMeaning() throws {
        let fixtures = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/LegacyV1", directoryHint: .isDirectory)
        let scenarioBytes = try Data(contentsOf: fixtures.appending(path: "scenario.json"))
        let invocationBytes = try Data(contentsOf: fixtures.appending(path: "invocation.json"))
        let journalBytes = try Data(contentsOf: fixtures.appending(path: "journal.json"))
        let evidenceBytes = try Data(contentsOf: fixtures.appending(path: "evidence.json"))
        let definition = try decoder.decode(ScenarioDefinition.self, from: scenarioBytes)
        let invocation = try decoder.decode(ScenarioInvocationIdentity.self, from: invocationBytes)
        let journal = try decoder.decode(ScenarioExecutionJournal.self, from: journalBytes)
        let envelope = try decoder.decode(ScenarioEvidenceEnvelope.self, from: evidenceBytes)
        #expect(definition.schemaVersion == 1)
        #expect(definition.definitionDigest == "39c7be7efc7df732a4ea0dbdf5392f3f5763b32c80137af2d69b7e87d043b077")
        #expect(definition.hasValidDigest)
        #expect(invocation.harnessVersion == "intent-lab-v1")
        #expect(envelope.schemaVersion == 1)
        #expect(journal.invocation == invocation)
        var ledger = ScenarioImportLedger()
        var run = try XCTestEvidenceImporter().importEvidence(
            data: evidenceBytes, definition: definition, journal: journal,
            artifactRoot: temporaryDirectory(), ledger: &ledger
        )
        #expect(run.outcome == .passed)
        run.xctestExitCode = 0
        let report = ScenarioReleaseCheckEvaluator.report(definition: definition, run: run)
        #expect(report.outcome == .passed)
        #expect(report.policyVersion == nil)
        #expect(try Data(contentsOf: fixtures.appending(path: "scenario.json")) == scenarioBytes)
    }

    @Test func reusableBasicAllowsDirectExecutionWithoutInventedStateEvidence() throws {
        let definition = try reusableBasicScenario()
        #expect(ScenarioValidator.issues(in: definition).filter { $0.severity == .error }.isEmpty)
        let restored = try decoder.decode(ScenarioDefinition.self, from: encoder.encode(definition))
        #expect(restored.hasValidDigest)
        #expect(restored.definitionDigest == definition.definitionDigest)
        let invocation = reusableInvocation(for: definition)
        var envelope = evidence(for: definition, invocation: invocation)
        envelope.schemaVersion = ScenarioEvidenceEnvelope.reusableSchemaVersion
        envelope.results.removeAll { $0.lane != .intentIntegration }
        envelope.results[0].observations = [:]
        envelope.results[0].assertionResults = []
        var ledger = ScenarioImportLedger()
        var run = try XCTestEvidenceImporter().importEvidence(
            data: try encoder.encode(envelope), definition: definition,
            journal: journal(for: definition, invocation: invocation, phase: .stopped),
            artifactRoot: temporaryDirectory(), ledger: &ledger
        )
        #expect(run.outcome == .passed)
        #expect(run.laneResults[0].observations.isEmpty)
        #expect(run.integration == definition.integration)
        #expect(run.runnerPackageVersion == "0.1.0")
        #expect(run.negotiatedCapabilities == ScenarioHarnessCapabilities.required(for: definition).sorted())
        var changed = run
        changed.integration?.version = "2.0"
        #expect(!ScenarioComparison.compare(baseline: run, candidate: changed).isDirectlyComparable)
        run.xctestExitCode = 0
        let release = ScenarioReleaseCheckEvaluator.report(definition: definition, run: run)
        #expect(release.outcome != .passed)
        #expect(release.policyVersion == ScenarioReleaseCheckEvaluator.reusablePolicyVersion)
        #expect(release.failures.contains { $0.contains("Exploratory") })
        #expect(release.failures.contains { $0.contains("Execution-only") })
    }

    @Test func reusablePassedEvidenceRequiresSupportedDistinctProofClaims() throws {
        let definition = try reusableBasicScenario()
        let invocation = reusableInvocation(for: definition)
        let evidenceJournal = journal(for: definition, invocation: invocation, phase: .stopped)
        var envelope = evidence(for: definition, invocation: invocation)
        envelope.results.removeAll { $0.lane != .intentIntegration }
        envelope.results[0].claims = nil
        try expectRejected(envelope, definition: definition, journal: evidenceJournal,
                           root: temporaryDirectory(), importer: XCTestEvidenceImporter())
        envelope.results[0].claims = [.executionCompleted, .executionCompleted]
        try expectRejected(envelope, definition: definition, journal: evidenceJournal,
                           root: temporaryDirectory(), importer: XCTestEvidenceImporter())
        envelope.results[0].claims = [.executionCompleted, .applicationStateChecked]
        try expectRejected(envelope, definition: definition, journal: evidenceJournal,
                           root: temporaryDirectory(), importer: XCTestEvidenceImporter())
    }

    @Test func reusableReturnClaimDoesNotBecomePersistenceProof() throws {
        var definition = try reusableBasicScenario()
        definition.purpose = .releaseRequirement
        definition.requiredClaims = [.executionCompleted, .returnedValueChecked]
        definition.goal.expectedBehavior = "The returned task ID is task-001."
        definition.directControl.outputFields = [.init(
            name: "taskID", type: .primitive(.string), displayName: "Task ID",
            path: [.init(kind: .property, name: "value")]
        )]
        let assertion = ScenarioAssertion(
            kind: .returnedField, observationKey: "taskID", expectedValue: .string("task-001"),
            explanation: "The returned task ID matches.", applicableLanes: [.intentIntegration]
        )
        definition.assertions = [assertion]
        definition.observationPlan = [.init(id: "taskID", source: .intentResult)]
        definition = try definition.frozen()
        #expect(ScenarioValidator.issues(in: definition).filter { $0.severity == .error }.isEmpty)
        let invocation = reusableInvocation(for: definition)
        var envelope = evidence(for: definition, invocation: invocation)
        envelope.schemaVersion = ScenarioEvidenceEnvelope.reusableSchemaVersion
        envelope.results.removeAll { $0.lane != .intentIntegration }
        envelope.results[0].observationSources = ["taskID": .appIntentsTesting]
        envelope.results[0].claims = [.executionCompleted, .returnedValueChecked]
        var ledger = ScenarioImportLedger()
        var run = try XCTestEvidenceImporter().importEvidence(
            data: try encoder.encode(envelope), definition: definition,
            journal: journal(for: definition, invocation: invocation, phase: .stopped),
            artifactRoot: temporaryDirectory(), ledger: &ledger
        )
        run.xctestExitCode = 0
        #expect(ScenarioReleaseCheckEvaluator.report(definition: definition, run: run).outcome == .passed)
        #expect(!ScenarioResultEvaluator.verifiedClaim(
            .applicationStateChecked, definition: definition, result: run.laneResults[0]
        ))
        envelope.results[0].observationSources = nil
        try expectRejected(envelope, definition: definition,
            journal: journal(for: definition, invocation: invocation, phase: .stopped),
            root: temporaryDirectory(), importer: XCTestEvidenceImporter())
    }

    @Test func reusableBehaviourRetainsFailedStateAfterSuccessfulReturn() throws {
        var definition = try reusableBasicScenario()
        definition.purpose = .releaseRequirement
        definition.checkMode = .behaviour
        definition.requiredClaims = [.executionCompleted, .applicationStateChecked]
        definition.goal.expectedBehavior = "The task remains complete in storage."
        let assertion = ScenarioAssertion(
            kind: .stateTransition, observationKey: "taskComplete", expectedValue: .boolean(true),
            explanation: "The stored task is complete.", applicableLanes: [.intentIntegration]
        )
        definition.assertions = [assertion]
        definition.observationPlan = [.init(id: "taskComplete", source: .entityQuery, operationID: "queryTask")]
        definition = try definition.frozen()
        #expect(ScenarioValidator.issues(in: definition).filter { $0.severity == .error }.isEmpty)
        let invocation = reusableInvocation(for: definition)
        var envelope = evidence(for: definition, invocation: invocation)
        envelope.schemaVersion = ScenarioEvidenceEnvelope.reusableSchemaVersion
        envelope.results.removeAll { $0.lane != .intentIntegration }
        envelope.results[0].observations = ["taskComplete": .boolean(false)]
        envelope.results[0].observationSources = ["taskComplete": .entityQuery]
        envelope.results[0].assertionResults = [.init(
            assertionID: assertion.id, passed: false, observedValue: .boolean(false), message: "Still incomplete"
        )]
        envelope.results[0].outcome = .failed
        var ledger = ScenarioImportLedger()
        var run = try XCTestEvidenceImporter().importEvidence(
            data: try encoder.encode(envelope), definition: definition,
            journal: journal(for: definition, invocation: invocation, phase: .stopped),
            artifactRoot: temporaryDirectory(), ledger: &ledger
        )
        #expect(run.outcome == .failed)
        run.xctestExitCode = 0
        #expect(ScenarioReleaseCheckEvaluator.report(definition: definition, run: run).outcome == .failed)

        envelope.results[0].observations = ["taskComplete": .boolean(true)]
        envelope.results[0].observationSources = ["taskComplete": .appIntentsTesting]
        envelope.results[0].assertionResults = [.init(
            assertionID: assertion.id, passed: true, observedValue: .boolean(true), message: "Return looked right"
        )]
        envelope.results[0].outcome = .passed
        envelope.results[0].claims = [.executionCompleted, .applicationStateChecked]
        try expectRejected(envelope, definition: definition,
            journal: journal(for: definition, invocation: invocation, phase: .stopped),
            root: temporaryDirectory(), importer: XCTestEvidenceImporter())
    }

    @Test func reusableVersionsAndInvalidProjectionPathsFailClosed() throws {
        let definition = try reusableBasicScenario()
        let invocation = reusableInvocation(for: definition)
        var envelope = evidence(for: definition, invocation: invocation)
        envelope.results.removeAll { $0.lane != .intentIntegration }
        envelope.results[0].observations = [:]
        envelope.results[0].assertionResults = []
        envelope.schemaVersion = ScenarioEvidenceEnvelope.currentSchemaVersion
        try expectRejected(envelope, definition: definition,
            journal: journal(for: definition, invocation: invocation, phase: .stopped),
            root: temporaryDirectory(), importer: XCTestEvidenceImporter())

        envelope.schemaVersion = ScenarioEvidenceEnvelope.reusableSchemaVersion
        envelope.invocation.harnessVersion = ScenarioInvocationIdentity.currentHarnessVersion
        try expectRejected(envelope, definition: definition,
            journal: journal(for: definition, invocation: invocation, phase: .stopped),
            root: temporaryDirectory(), importer: XCTestEvidenceImporter())

        envelope.invocation.harnessVersion = ScenarioInvocationIdentity.reusableHarnessVersion
        envelope.integration?.digest = String(repeating: "b", count: 64)
        try expectRejected(envelope, definition: definition,
            journal: journal(for: definition, invocation: invocation, phase: .stopped),
            root: temporaryDirectory(), importer: XCTestEvidenceImporter())
        envelope.integration = definition.integration
        envelope.negotiatedCapabilities = ["environment-payload"]
        try expectRejected(envelope, definition: definition,
            journal: journal(for: definition, invocation: invocation, phase: .stopped),
            root: temporaryDirectory(), importer: XCTestEvidenceImporter())

        var invalid = definition
        invalid.directControl.outputFields = [.init(
            name: "taskID", type: .primitive(.string),
            path: [.init(kind: .index, index: 100)]
        )]
        #expect(ScenarioValidator.issues(in: invalid, requireFrozenDigest: false)
            .contains { $0.path.contains("outputFields[0].path") })
        invalid.directControl.outputFields[0].path = [.init(kind: .count), .init(kind: .property, name: "id")]
        #expect(ScenarioValidator.issues(in: invalid, requireFrozenDigest: false)
            .contains { $0.message.contains("final path component") })
    }

    @Test func reusableCapabilitiesFollowObservationPlan() throws {
        var definition = try reusableBasicScenario()
        #expect(ScenarioHarnessCapabilities.required(for: definition) == [
            "environment-payload", "direct-intent-execution"
        ])
        definition.fixture.preparationOperation = "none"
        definition.fixture.cleanupOperation = "readOnly"
        #expect(!ScenarioHarnessCapabilities.required(for: definition).contains("preparation"))
        definition.observationPlan = [.init(id: "taskComplete", source: .entityQuery, operationID: "queryTask")]
        #expect(ScenarioHarnessCapabilities.required(for: definition).contains("entity-query"))
        #expect(!ScenarioHarnessCapabilities.required(for: definition).contains("accessible-result"))
        definition.coverage.siri = .required
        let capabilities = ScenarioHarnessCapabilities.required(for: definition)
        #expect(capabilities.contains("siri-completion"))
        #expect(capabilities.contains("invocation-correlation"))
        #expect(!capabilities.contains("fixture-reset"))
        #expect(ScenarioHarnessCapabilities.required(for: try scenario()).contains("fixture-reset"))
    }

    @Test func reusableTransportMapsOnlyDeviceFieldsAndKeepsProjectionPath() throws {
        var definition = try reusableBasicScenario()
        definition.directControl.outputFields = [.init(
            name: "taskID", type: .primitive(.string), displayName: "Task ID",
            path: [.init(kind: .property, name: "value"), .init(kind: .index, index: 0)]
        )]
        definition.observationPlan = [.init(id: "taskID", source: .intentResult)]
        definition = try definition.frozen()
        let payload = try XCTestRunInvocationTransport.scenarioPayload(for: definition)
        let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let target = try #require(object["target"] as? [String: Any])
        let goal = try #require(object["goal"] as? [String: Any])
        let direct = try #require(object["directControl"] as? [String: Any])
        let output = try #require((direct["outputFields"] as? [[String: Any]])?.first)
        let path = try #require(output["path"] as? [[String: Any]])
        #expect(target["bundleIdentifier"] as? String == definition.target.bundleIdentifier)
        #expect(target["projectPath"] == nil)
        #expect(goal["expectedBehavior"] == nil)
        #expect(direct["linkedFeatureRunID"] == nil)
        #expect(output["displayName"] as? String == "Task ID")
        #expect(path.map { $0["kind"] as? String } == ["property", "index"])
        #expect((object["integration"] as? [String: Any])?["digest"] as? String == definition.integration?.digest)
    }

    @Test func connectionReceiptRequiresOneBoundAttachment() throws {
        let root = try temporaryDirectory()
        let definition = try reusableBasicScenario()
        let receipt = ScenarioConnectionReceipt(
            schemaVersion: 1, integration: try #require(definition.integration),
            targetBundleIdentifier: definition.target.bundleIdentifier,
            testBundleIdentifier: "dev.example.TasksUITests", harnessProtocol: "intent-lab-v2",
            runnerPackageVersion: "0.2.0-dev", capabilities: ["direct-intent-execution", "environment-payload"],
            inspectedAt: Date()
        )
        let receiptName = "IntentLabConnectionReceipt-\(UUID().uuidString).json"
        let exportedName = "receipt.json"
        try encoder.encode(receipt).write(to: root.appending(path: exportedName))
        let attachment: [String: Any] = [
            "suggestedHumanReadableName": receiptName, "exportedFileName": exportedName
        ]
        func writeManifest(_ attachments: [[String: Any]]) throws {
            let manifest: [[String: Any]] = [[
                "testIdentifier": "IntentLabScenarioTests/testIntentLabConnection()",
                "attachments": attachments
            ]]
            try JSONSerialization.data(withJSONObject: manifest).write(to: root.appending(path: "manifest.json"))
        }
        try writeManifest([attachment])
        #expect(try XcodeTestExecutor.connectionReceipt(in: root).integration == definition.integration)
        try writeManifest([attachment, attachment])
        #expect(throws: XcodeTestExecutorError.self) {
            _ = try XcodeTestExecutor.connectionReceipt(in: root)
        }
    }

    @Test func connectionFingerprintChangesWithSigningAndPackageInputs() throws {
        let root = try temporaryDirectory()
        let project = root.appending(path: "Tasks.xcodeproj", directoryHint: .isDirectory)
        let products = root.appending(path: "Products", directoryHint: .isDirectory)
        let app = products.appending(path: "Tasks.app", directoryHint: .isDirectory)
        let test = products.appending(path: "TasksUITests.xctest", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: test, withIntermediateDirectories: true)
        let pbxproj = project.appending(path: "project.pbxproj")
        let appInfo = app.appending(path: "Info.plist")
        let signature = app.appending(path: "_CodeSignature/CodeResources")
        let resolved = project.appending(path: "project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        try FileManager.default.createDirectory(at: signature.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("project-v1".utf8).write(to: pbxproj)
        try Data("info-v1".utf8).write(to: appInfo)
        try Data("signature-v1".utf8).write(to: signature)
        try Data("package-v1".utf8).write(to: resolved)
        let source = products.appending(path: "Tasks.xctestrun")
        try Data("run-v1".utf8).write(to: source)
        let paths = XCTestRunProductPaths(
            sourceURL: source, appBundleURL: app, testHostURL: test, testBundleURL: test
        )
        let configuration = XcodeTestConfiguration(
            containerPath: project.path, isWorkspace: false, scheme: "Tasks",
            testTarget: "TasksUITests", testBundleIdentifier: "dev.example.TasksUITests",
            destinationIdentifier: "device", generatedResourceDirectory: root.path,
            xcodebuildPath: "/bin/echo"
        )
        let original = try XcodeTestExecutor.buildInputsDigest(configuration: configuration, products: paths)
        let originalProducts = XcodeTestExecutor.productMetadataDigest(products: paths)
        try Data("signature-v2".utf8).write(to: signature)
        let signed = try XcodeTestExecutor.buildInputsDigest(configuration: configuration, products: paths)
        #expect(signed != original)
        #expect(XcodeTestExecutor.productMetadataDigest(products: paths) != originalProducts)
        try Data("package-v2".utf8).write(to: resolved)
        #expect(try XcodeTestExecutor.buildInputsDigest(configuration: configuration, products: paths) != signed)

        let workspace = root.appending(path: "Tasks.xcworkspace", directoryHint: .isDirectory)
        let workspaceScheme = workspace.appending(path: "xcshareddata/xcschemes/Tasks.xcscheme")
        try FileManager.default.createDirectory(at: workspaceScheme.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<Workspace version=\"1.0\"><FileRef location=\"group:Tasks.xcodeproj\"/></Workspace>".utf8)
            .write(to: workspace.appending(path: "contents.xcworkspacedata"))
        try Data("scheme-v1".utf8).write(to: workspaceScheme)
        var workspaceConfiguration = configuration
        workspaceConfiguration.containerPath = workspace.path
        workspaceConfiguration.isWorkspace = true
        let workspaceDigest = try XcodeTestExecutor.buildInputsDigest(configuration: workspaceConfiguration, products: paths)
        try Data("scheme-v2".utf8).write(to: workspaceScheme)
        #expect(try XcodeTestExecutor.buildInputsDigest(configuration: workspaceConfiguration, products: paths) != workspaceDigest)
    }

    @Test func v2DeclaredBuildSettingsCannotClaimVerifiedReadiness() async throws {
        let root = try temporaryDirectory()
        let persistence = ScenarioPersistence(rootDirectory: root)
        let executor = XcodeTestExecutor(workDirectory: root, persistence: persistence)
        let definition = try reusableBasicScenario()
        let configuration = XcodeTestConfiguration(
            containerPath: root.path, isWorkspace: false, scheme: "Tasks",
            testTarget: "TasksUITests", testBundleIdentifier: "dev.example.TasksUITests",
            destinationIdentifier: "", generatedResourceDirectory: root.path,
            harnessVersion: "intent-lab-v2",
            harnessCapabilities: ScenarioHarnessCapabilities.required(for: definition).sorted(),
            applicationSigningConfigured: true, testSigningConfigured: true,
            selectedTestProductID: "project#test", selectedApplicationProductID: "project#app"
        )
        let report = await executor.preflight(
            definition: definition, configuration: configuration, projectTrusted: true
        )
        #expect(report.checks.first(where: { $0.id == "harness" })?.state == .blocked)
        #expect(report.checks.first(where: { $0.id == "capability.direct-intent-execution" })?.state == .blocked)
    }

    @Test func validationKeepsMissingNullAndTypedValuesDistinct() throws {
        var definition = try scenario()
        definition.directControl.parameters = [
            .init(name: "defaulted", type: .primitive(.string), isOptional: true, presence: .missing),
            .init(name: "cleared", type: .primitive(.string), isOptional: true, presence: .value(.null)),
            .init(name: "priority", type: .enumeration(typeIdentifier: "Priority", allowedCases: ["high"]), isOptional: false,
                  presence: .value(.enumeration(.init(typeIdentifier: "Priority", caseIdentifier: "low")))),
            .init(name: "score", type: .primitive(.number), isOptional: false, presence: .value(.number(.infinity)))
        ]
        let issues = ScenarioValidator.issues(in: definition, requireFrozenDigest: false)

        #expect(!issues.contains { $0.path.contains("defaulted") })
        #expect(!issues.contains { $0.path.contains("cleared") })
        #expect(issues.contains { $0.message.contains("allowlist") })
        #expect(issues.contains { $0.message.contains("finite") })
    }

    @Test func duplicateAssertionEvidenceIsRejectedWithoutConsumingInvocation() throws {
        let definition = try scenario()
        let invocation = invocation(for: definition)
        var envelope = evidence(for: definition, invocation: invocation)
        envelope.results[0].assertionResults.append(envelope.results[0].assertionResults[0])
        try expectRejected(envelope, definition: definition,
            journal: journal(for: definition, invocation: invocation, phase: .stopped),
            root: temporaryDirectory(), importer: XCTestEvidenceImporter())
    }

    @Test func rejectedEvidenceImmediatelyExposesRecovery() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ScenarioPersistence(rootDirectory: root)
        let executor = XcodeTestExecutor(workDirectory: root.appending(path: "Executor"), persistence: persistence)
        let definition = try scenario()
        let invocation = invocation(for: definition)
        let stopped = journal(for: definition, invocation: invocation, phase: .stopped)
        try await executor.finishEvidenceValidation(journal: stopped, accepted: false)
        #expect(await executor.reservation(for: invocation.destinationIdentifier) != nil)
        #expect(try await executor.currentRecoveryJournals().map(\.id) == [stopped.id])
        do {
            _ = try await executor.beginQuarantineClear(
                destinationIdentifier: invocation.destinationIdentifier,
                fixtureReadinessProven: false
            )
            Issue.record("Clearing quarantine without proven readiness unexpectedly succeeded.")
        } catch is XcodeTestExecutorError {
            // The device remains reserved until readiness is proven.
        } catch {
            throw error
        }
        let configuration = XcodeTestConfiguration(
            containerPath: root.path, isWorkspace: false, scheme: "Fixture",
            testTarget: "FixtureUITests", testBundleIdentifier: "dev.example.FixtureUITests",
            destinationIdentifier: invocation.destinationIdentifier,
            generatedResourceDirectory: root.path
        )
        let report = await executor.preflight(
            definition: definition, configuration: configuration, projectTrusted: true
        )
        #expect(report.checks.first(where: { $0.id == "reservation" })?.state == .blocked)
    }

    @Test func validEvidenceImportsOnceAndRequiresEveryLane() throws {
        let definition = try scenario()
        let invocation = invocation(for: definition)
        let envelope = evidence(for: definition, invocation: invocation)
        var ledger = ScenarioImportLedger()
        let root = try temporaryDirectory()
        let importer = XCTestEvidenceImporter()

        var invalid = envelope
        invalid.testCount = 0
        #expect(throws: ScenarioEvidenceImportError.invalidTestCount) {
            _ = try importer.importEvidence(
                data: try encoder.encode(invalid), definition: definition,
                journal: journal(for: definition, invocation: invocation, phase: .stopped),
                artifactRoot: root, ledger: &ledger
            )
        }
        #expect(ledger == ScenarioImportLedger())

        let run = try importer.importEvidence(
            data: try encoder.encode(envelope), definition: definition,
            journal: journal(for: definition, invocation: invocation, phase: .stopped),
            artifactRoot: root, ledger: &ledger
        )
        #expect(run.outcome == .passed)
        #expect(run.executionStatus == .completed)

        #expect(throws: ScenarioEvidenceImportError.self) {
            _ = try importer.importEvidence(
                data: try encoder.encode(envelope), definition: definition,
                journal: journal(for: definition, invocation: invocation, phase: .stopped),
                artifactRoot: root, ledger: &ledger
            )
        }

        var missingSiri = envelope
        missingSiri.invocation.id = UUID()
        missingSiri.invocation.nonce = UUID().uuidString
        missingSiri.results.removeAll { $0.lane == .siri }
        var missingJournal = journal(for: definition, invocation: missingSiri.invocation, phase: .stopped)
        missingJournal.invocation = missingSiri.invocation
        #expect(throws: ScenarioEvidenceImportError.self) {
            var freshLedger = ScenarioImportLedger()
            _ = try importer.importEvidence(
                data: try encoder.encode(missingSiri), definition: definition,
                journal: missingJournal, artifactRoot: root, ledger: &freshLedger
            )
        }
    }

    @Test func mismatchedIdentityZeroTestsAndDuplicateAttemptsCannotPass() throws {
        let definition = try scenario()
        let invocation = invocation(for: definition)
        let root = try temporaryDirectory()
        let importer = XCTestEvidenceImporter()

        var wrongBundle = evidence(for: definition, invocation: invocation)
        wrongBundle.sourceBundleIdentifier = "invalid.bundle"
        try expectRejected(wrongBundle, definition: definition, journal: journal(for: definition, invocation: invocation, phase: .running), root: root, importer: importer)

        var zeroTests = evidence(for: definition, invocation: invocation)
        zeroTests.testCount = 0
        try expectRejected(zeroTests, definition: definition, journal: journal(for: definition, invocation: invocation, phase: .running), root: root, importer: importer)

        var duplicate = evidence(for: definition, invocation: invocation)
        duplicate.results.append(duplicate.results[0])
        try expectRejected(duplicate, definition: definition, journal: journal(for: definition, invocation: invocation, phase: .running), root: root, importer: importer)

        var wrongDestination = evidence(for: definition, invocation: invocation)
        wrongDestination.invocation.destinationIdentifier = "other-device"
        try expectRejected(wrongDestination, definition: definition, journal: journal(for: definition, invocation: invocation, phase: .running), root: root, importer: importer)
    }

    @Test func artifactTraversalAndDigestMismatchAreRejected() throws {
        let definition = try scenario()
        let invocation = invocation(for: definition)
        let root = try temporaryDirectory()
        let importer = XCTestEvidenceImporter()

        var traversal = evidence(for: definition, invocation: invocation)
        traversal.results[0].artifacts = [.init(
            kind: .screenshot, filename: "outside.png", relativePath: "../outside.png",
            contentType: "image/png", byteCount: 1, sha256: "bad"
        )]
        try expectRejected(traversal, definition: definition, journal: journal(for: definition, invocation: invocation, phase: .running), root: root, importer: importer)

        let payload = Data("evidence".utf8)
        try payload.write(to: root.appending(path: "evidence.json"))
        var digestMismatch = evidence(for: definition, invocation: invocation)
        digestMismatch.results[0].artifacts = [.init(
            kind: .evidenceJSON, filename: "evidence.json", relativePath: "evidence.json",
            contentType: "application/json", byteCount: payload.count, sha256: "bad"
        )]
        try expectRejected(digestMismatch, definition: definition, journal: journal(for: definition, invocation: invocation, phase: .running), root: root, importer: importer)
    }

    @Test func intentEvidenceCannotSatisfyRequiredSiriReleaseCheck() throws {
        let definition = try scenario()
        let invocation = invocation(for: definition)
        let envelope = evidence(for: definition, invocation: invocation)
        let intentOnly = ScenarioRun(
            id: invocation.id, scenarioID: definition.id, scenarioVersion: definition.version,
            scenarioDigest: definition.definitionDigest, invocation: invocation,
            startedAt: .now, completedAt: .now, environment: envelope.environment,
            executionStatus: .completed, outcome: .passed,
            laneResults: envelope.results.filter { $0.lane == .intentIntegration },
            linkedFeatureRunID: nil, importedAt: .now
        )

        let report = ScenarioReleaseCheckEvaluator.report(definition: definition, run: intentOnly)
        #expect(report.outcome == .incompleteOrIncompatibleEvidence)
        #expect(report.failures.contains { $0.contains("Siri") })
    }

    @Test func requiredSiriLaneNeedsItsOwnRequiredOutcomeAssertion() throws {
        var definition = try scenario()
        definition.assertions = [ScenarioAssertion(
            kind: .entityIdentifier,
            observationKey: "selectedNoteID",
            expectedValue: .string("packing-001"),
            explanation: "The direct intent selected the note.",
            applicableLanes: [.intentIntegration]
        )]
        definition = try definition.frozen()
        let siriEvaluation = ScenarioResultEvaluator.evaluate(
            definition: definition,
            lane: .siri,
            observations: [:],
            executionStatus: .completed
        )
        #expect(siriEvaluation.0 == .needsReview)
        #expect(ScenarioValidator.issues(in: definition).contains {
            $0.path == "coverage.siri" && $0.severity == .error
        })

        let boundInvocation = invocation(for: definition)
        let envelope = evidence(for: definition, invocation: boundInvocation)
        var successfulRun = ScenarioRun(
            id: boundInvocation.id,
            scenarioID: definition.id,
            scenarioVersion: definition.version,
            scenarioDigest: definition.definitionDigest,
            invocation: boundInvocation,
            startedAt: .now,
            completedAt: .now,
            environment: envelope.environment,
            executionStatus: .completed,
            outcome: .passed,
            laneResults: envelope.results,
            linkedFeatureRunID: nil,
            importedAt: .now
        )
        successfulRun.xctestExitCode = 0
        let release = ScenarioReleaseCheckEvaluator.report(definition: definition, run: successfulRun)
        #expect(release.outcome != .passed)
        #expect(release.failures.contains { $0.contains("Siri outcome lane has no required observable") })
    }

    @Test func comparisonRejectsUnstatedEnvironmentDrift() throws {
        let definition = try scenario()
        let invocation = invocation(for: definition)
        var ledger = ScenarioImportLedger()
        let envelope = evidence(for: definition, invocation: invocation)
        let run = try XCTestEvidenceImporter().importEvidence(
            data: try encoder.encode(envelope), definition: definition,
            journal: journal(for: definition, invocation: invocation, phase: .stopped),
            artifactRoot: try temporaryDirectory(), ledger: &ledger
        )
        var changed = run
        changed.environment.operatingSystem = "iOS 28"

        #expect(!ScenarioComparison.compare(baseline: run, candidate: changed).isDirectlyComparable)
        #expect(ScenarioComparison.compare(
            baseline: run, candidate: changed, statedChangedDimensions: ["operatingSystem"]
        ).isDirectlyComparable)
    }

    @Test func releaseRejectsUnstatedDriftAndAcceptsRunBoundIntentionalChange() throws {
        let definition = try scenario()
        let invocation = invocation(for: definition)
        var ledger = ScenarioImportLedger()
        let envelope = evidence(for: definition, invocation: invocation)
        let baseline = try XCTestEvidenceImporter().importEvidence(
            data: try encoder.encode(envelope), definition: definition,
            journal: journal(for: definition, invocation: invocation, phase: .stopped),
            artifactRoot: try temporaryDirectory(), ledger: &ledger
        )
        var candidate = baseline
        candidate.id = UUID()
        candidate.invocation.id = candidate.id
        candidate.environment.operatingSystem = "iOS 28"
        candidate.xctestExitCode = 0

        let incompatible = ScenarioComparison.compare(baseline: baseline, candidate: candidate)
        #expect(ScenarioReleaseCheckEvaluator.report(
            definition: definition,
            run: candidate,
            comparison: incompatible
        ).outcome == .incompleteOrIncompatibleEvidence)

        candidate.statedChangedDimensions = ["operatingSystem"]
        let accepted = ScenarioComparison.compare(baseline: baseline, candidate: candidate)
        #expect(accepted.isDirectlyComparable)
        #expect(ScenarioReleaseCheckEvaluator.report(
            definition: definition,
            run: candidate,
            comparison: accepted
        ).outcome == .passed)
    }

    @Test func frozenVersionCannotBeRewrittenWithAnotherDigest() async throws {
        let root = try temporaryDirectory()
        let persistence = ScenarioPersistence(rootDirectory: root)
        let original = try scenario()
        try await persistence.saveDefinition(original)

        var edited = original
        edited.goal.requestText = "Use different approved wording"
        edited = try edited.frozen()
        #expect(edited.version == original.version)
        #expect(edited.definitionDigest != original.definitionDigest)
        await #expect(throws: ScenarioPersistenceError.self) {
            try await persistence.saveDefinition(edited)
        }
    }

    @Test func corruptDefinitionCannotDisappearFromReleaseInventory() async throws {
        let root = try temporaryDirectory()
        let persistence = ScenarioPersistence(rootDirectory: root)
        let original = try scenario()
        try await persistence.saveDefinition(original)
        let path = root.appending(path: "Definitions/\(original.id.uuidString)/v\(original.version)-\(original.definitionDigest).json")
        try Data("{corrupt".utf8).write(to: path, options: .atomic)

        await #expect(throws: ScenarioPersistenceError.self) {
            _ = try await persistence.loadDefinitions()
        }
    }

    @Test func corruptRunCannotDisappearFromReleaseInventory() async throws {
        let root = try temporaryDirectory()
        let persistence = ScenarioPersistence(rootDirectory: root)
        let definition = try scenario()
        let invocation = invocation(for: definition)
        var ledger = ScenarioImportLedger()
        let run = try XCTestEvidenceImporter().importEvidence(
            data: try encoder.encode(evidence(for: definition, invocation: invocation)),
            definition: definition,
            journal: journal(for: definition, invocation: invocation, phase: .stopped),
            artifactRoot: try temporaryDirectory(), ledger: &ledger
        )
        _ = try await persistence.saveRun(run, artifactRoot: nil)
        let path = root.appending(path: "Runs/\(run.scenarioID.uuidString)/\(run.id.uuidString)/run.json")
        try Data("{corrupt".utf8).write(to: path, options: .atomic)

        await #expect(throws: ScenarioPersistenceError.self) {
            _ = try await persistence.loadRuns()
        }
        await #expect(throws: ScenarioPersistenceError.self) {
            _ = try await persistence.loadRunPage(scenarioID: run.scenarioID, offset: 0, limit: 10)
        }
    }

    @Test func latestFrozenVersionSupersedesOldProjectAssignment() throws {
        let oldProject = UUID()
        let newProject = UUID()
        var old = try scenario()
        old.projectID = oldProject
        old = try old.frozen()
        var latest = old
        latest.version += 1
        latest.projectID = newProject
        latest = try latest.frozen()

        let selected = ScenarioDefinition.latestVersions(in: [latest, old])
        #expect(selected.count == 1)
        #expect(selected[0].version == latest.version)
        #expect(selected.filter { $0.projectID == oldProject }.isEmpty)
        #expect(selected.filter { $0.projectID == newProject }.count == 1)
    }

    @Test func nonzeroXCTestExitAndNoRequiredOutcomeCannotPassRelease() throws {
        let original = try scenario()
        let invocation = invocation(for: original)
        var ledger = ScenarioImportLedger()
        let envelope = evidence(for: original, invocation: invocation)
        var run = try XCTestEvidenceImporter().importEvidence(
            data: try encoder.encode(envelope), definition: original,
            journal: journal(for: original, invocation: invocation, phase: .stopped),
            artifactRoot: try temporaryDirectory(), ledger: &ledger
        )
        let legacyDecoded = try decoder.decode(ScenarioRun.self, from: encoder.encode(run))
        #expect(legacyDecoded.xctestExitCode == nil)
        let legacy = ScenarioReleaseCheckEvaluator.report(definition: original, run: run)
        #expect(legacy.outcome == .incompleteOrIncompatibleEvidence)
        #expect(legacy.failures.contains { $0.contains("does not record a successful XCTest exit") })
        run.xctestExitCode = 0
        #expect(ScenarioReleaseCheckEvaluator.report(definition: original, run: run).outcome == .passed)
        run.xctestExitCode = 1
        let failedTest = ScenarioReleaseCheckEvaluator.report(definition: original, run: run)
        #expect(failedTest.outcome != .passed)
        #expect(failedTest.failures.contains { $0.contains("XCTest failed") })

        var optional = original
        optional.coverage.appFeature = .optional
        optional.coverage.intentIntegration = .optional
        optional.coverage.siri = .optional
        optional.assertions = optional.assertions.map { assertion in
            var copy = assertion
            copy.required = false
            return copy
        }
        optional = try optional.frozen()
        run.scenarioDigest = optional.definitionDigest
        run.xctestExitCode = 0
        #expect(ScenarioResultEvaluator.overall(definition: optional, laneResults: run.laneResults) == .needsReview)
        let noGate = ScenarioReleaseCheckEvaluator.report(definition: optional, run: run)
        #expect(noGate.outcome == .incompleteOrIncompatibleEvidence)
        #expect(noGate.failures.contains { $0.contains("no required evidence lane") })
    }

    @Test func releaseRejectsMissingOrDuplicateRequiredAssertionEvidence() throws {
        let definition = try scenario()
        let boundInvocation = invocation(for: definition)
        var ledger = ScenarioImportLedger()
        let envelope = evidence(for: definition, invocation: boundInvocation)
        var run = try XCTestEvidenceImporter().importEvidence(
            data: try encoder.encode(envelope), definition: definition,
            journal: journal(for: definition, invocation: boundInvocation, phase: .stopped),
            artifactRoot: try temporaryDirectory(), ledger: &ledger
        )
        run.xctestExitCode = 0
        #expect(ScenarioReleaseCheckEvaluator.report(definition: definition, run: run).outcome == .passed)
        var pendingJournal = journal(for: definition, invocation: boundInvocation, phase: .stopped)
        #expect(!ScenarioReleaseCheckEvaluator.acceptedJournal(for: run, in: [pendingJournal]))
        #expect(ScenarioReleaseCheckEvaluator.report(
            definition: definition, run: run, journalAccepted: false
        ).outcome == .incompleteOrIncompatibleEvidence)
        pendingJournal.evidenceAccepted = true
        #expect(ScenarioReleaseCheckEvaluator.acceptedJournal(for: run, in: [pendingJournal]))
        #expect(ScenarioReleaseCheckEvaluator.report(
            definition: definition, run: run, journalAccepted: true
        ).outcome == .passed)
        var legacyJSON = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(pendingJournal)
        ) as? [String: Any])
        legacyJSON.removeValue(forKey: "evidenceAccepted")
        let legacyJournal = try JSONDecoder().decode(
            ScenarioExecutionJournal.self,
            from: JSONSerialization.data(withJSONObject: legacyJSON)
        )
        #expect(legacyJournal.evidenceAccepted == nil)

        let laneIndex = try #require(run.laneResults.firstIndex { $0.lane == .intentIntegration })
        let completeResults = run.laneResults[laneIndex].assertionResults
        #expect(!completeResults.isEmpty)

        run.laneResults[laneIndex].assertionResults = []
        let missing = ScenarioReleaseCheckEvaluator.report(definition: definition, run: run)
        #expect(missing.outcome != .passed)
        #expect(missing.failures.contains { $0.contains("missing or failed") })

        run.laneResults[laneIndex].assertionResults = completeResults + [completeResults[0]]
        #expect(ScenarioReleaseCheckEvaluator.report(definition: definition, run: run).outcome != .passed)
    }

    @Test func recoveryPolicyQuarantinesUncertainDeviceFailuresOnlyAfterLaunch() {
        #expect(!ScenarioExecutionRecoveryPolicy.requiresQuarantine(
            deviceTestLaunched: false,
            failure: .buildFailure
        ))
        #expect(!ScenarioExecutionRecoveryPolicy.requiresQuarantine(
            deviceTestLaunched: true,
            failure: .buildFailure
        ))
        for failure in [
            ScenarioRecoveryFailure.cancellation,
            .timeout,
            .deviceDisconnect,
            .incompleteResultBundle,
            .invalidEvidence,
            .unexpected,
        ] {
            #expect(ScenarioExecutionRecoveryPolicy.requiresQuarantine(
                deviceTestLaunched: true,
                failure: failure
            ))
            #expect(!ScenarioExecutionRecoveryPolicy.requiresQuarantine(
                deviceTestLaunched: false,
                failure: failure
            ))
        }
    }

    @Test func completedFailedOutcomeCanBeRetainedButTimeoutCannotClearQuarantine() throws {
        let definition = try scenario()
        let invocation = invocation(for: definition)
        let envelope = evidence(for: definition, invocation: invocation)
        var ledger = ScenarioImportLedger()
        var run = try XCTestEvidenceImporter().importEvidence(
            data: try encoder.encode(envelope), definition: definition,
            journal: journal(for: definition, invocation: invocation, phase: .stopped),
            artifactRoot: temporaryDirectory(), ledger: &ledger
        )
        let final = ScenarioEvidenceAttachment(
            url: URL(filePath: "/tmp/final.json"), name: "IntentLabEvidence-\(invocation.id.uuidString).json"
        )
        run.laneResults[0].outcome = .failed
        run.outcome = .failed
        #expect(ScenarioExecutionRecoveryPolicy.acceptsFinalEvidence(
            attachments: [final], runs: [run], xctestExitCode: 0
        ))
        var emptyRun = run
        emptyRun.laneResults = []
        #expect(!ScenarioExecutionRecoveryPolicy.acceptsFinalEvidence(
            attachments: [final], runs: [emptyRun], xctestExitCode: 0
        ))
        run.laneResults[0].executionStatus = .timedOut
        #expect(!ScenarioExecutionRecoveryPolicy.acceptsFinalEvidence(
            attachments: [final], runs: [run], xctestExitCode: 0
        ))
        run.laneResults[0].executionStatus = .completed
        let checkpoint = ScenarioEvidenceAttachment(
            url: URL(filePath: "/tmp/checkpoint.json"),
            name: "IntentLabEvidence-\(invocation.id.uuidString)-checkpoint.json"
        )
        #expect(!ScenarioExecutionRecoveryPolicy.acceptsFinalEvidence(
            attachments: [checkpoint], runs: [run], xctestExitCode: 0
        ))
        #expect(!ScenarioExecutionRecoveryPolicy.acceptsFinalEvidence(
            attachments: [final], runs: [run], xctestExitCode: 1
        ))
    }

    @Test func initialJournalSaveFailureReleasesOnlyItsReservation() async throws {
        let root = try temporaryDirectory()
        let blockedRoot = root.appending(path: "not-a-directory")
        try Data("blocked".utf8).write(to: blockedRoot)
        let definition = try scenario()
        let invocation = invocation(for: definition)
        let preparing = journal(for: definition, invocation: invocation, phase: .preparing)
        let destination = invocation.destinationIdentifier

        let blockedExecutor = XcodeTestExecutor(
            workDirectory: root.appending(path: "BlockedExecutor"),
            persistence: ScenarioPersistence(rootDirectory: blockedRoot)
        )
        do {
            try await blockedExecutor.persistPreparingJournal(preparing)
            Issue.record("Saving the initial journal unexpectedly succeeded.")
        } catch {
            #expect(await blockedExecutor.reservation(for: destination) == nil)
        }

        let persistence = ScenarioPersistence(rootDirectory: root.appending(path: "Writable"))
        let executor = XcodeTestExecutor(
            workDirectory: root.appending(path: "WritableExecutor"), persistence: persistence
        )
        try await executor.persistPreparingJournal(preparing)
        #expect(await executor.reservation(for: destination) == .reserved(invocationID: invocation.id))
        #expect(try await persistence.loadJournals().contains { $0.id == invocation.id && $0.phase == .preparing })
        await #expect(throws: XcodeTestExecutorError.self) {
            try await executor.clearQuarantine(
                destinationIdentifier: destination, fixtureReadinessProven: true
            )
        }
        #expect(await executor.reservation(for: destination) == .reserved(invocationID: invocation.id))
    }

    @Test func corruptJournalCannotDisappearFromRecoveryInventory() async throws {
        let root = try temporaryDirectory()
        let persistence = ScenarioPersistence(rootDirectory: root)
        let definition = try scenario()
        let invocation = invocation(for: definition)
        try await persistence.saveJournal(journal(
            for: definition, invocation: invocation, phase: .running
        ))
        let path = root.appending(path: "Journals/\(invocation.id.uuidString).json")
        try Data("{corrupt".utf8).write(to: path, options: .atomic)

        await #expect(throws: ScenarioPersistenceError.self) {
            _ = try await persistence.loadJournals()
        }

        try await persistence.saveJournal(journal(
            for: definition, invocation: invocation, phase: .running
        ))
        try FileManager.default.moveItem(
            at: path,
            to: root.appending(path: "Journals/\(UUID().uuidString).json")
        )
        await #expect(throws: ScenarioPersistenceError.self) {
            _ = try await persistence.loadJournals()
        }
    }

    @Test func recoveryRequiredJournalSurvivesRelaunchUntilExplicitlyCleared() async throws {
        let root = try temporaryDirectory()
        let persistence = ScenarioPersistence(rootDirectory: root)
        let definition = try scenario()
        let invocation = invocation(for: definition)
        var interrupted = journal(for: definition, invocation: invocation, phase: .recoveryRequired)
        interrupted.derivedDataPath = root.appending(path: "DerivedData", directoryHint: .isDirectory).path
        let products = URL(filePath: interrupted.derivedDataPath).appending(path: "Build/Products", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        let stalePayload = products.appending(path: "IntentLab-\(invocation.id.uuidString).xctestrun")
        try Data("private invocation payload".utf8).write(to: stalePayload)
        interrupted.recoveryReason = "Device-side termination is unverified."
        try await persistence.saveJournal(interrupted)

        let relaunched = XcodeTestExecutor(
            workDirectory: root.appending(path: "Executor", directoryHint: .isDirectory),
            persistence: persistence
        )
        let recovered = try await relaunched.reconcileInterruptedJournals()

        #expect(recovered.map(\.id) == [interrupted.id])
        #expect(await relaunched.reservation(for: invocation.destinationIdentifier) != nil)
        #expect(!FileManager.default.fileExists(atPath: stalePayload.path))

        _ = try await relaunched.beginQuarantineClear(
            destinationIdentifier: invocation.destinationIdentifier,
            fixtureReadinessProven: true
        )
        await #expect(throws: XcodeTestExecutorError.self) {
            _ = try await relaunched.beginQuarantineClear(
                destinationIdentifier: invocation.destinationIdentifier,
                fixtureReadinessProven: true
            )
        }
        await relaunched.endQuarantineClear(destinationIdentifier: invocation.destinationIdentifier)

        await #expect(throws: XcodeTestExecutorError.self) {
            try await relaunched.clearQuarantine(
                destinationIdentifier: invocation.destinationIdentifier,
                fixtureReadinessProven: false
            )
        }
        #expect(await relaunched.reservation(for: invocation.destinationIdentifier) != nil)

        try await relaunched.clearQuarantine(
            destinationIdentifier: invocation.destinationIdentifier,
            fixtureReadinessProven: true
        )
        let persisted = try await persistence.loadJournals()
        #expect(persisted.first(where: { $0.id == interrupted.id })?.phase == .stopped)

        let nextLaunch = XcodeTestExecutor(
            workDirectory: root.appending(path: "Executor-2", directoryHint: .isDirectory),
            persistence: persistence
        )
        #expect(try await nextLaunch.reconcileInterruptedJournals().isEmpty)
    }

    @Test func inSessionCancellationQuarantinesAndCanBeExplicitlyCleared() async throws {
        let root = try temporaryDirectory()
        let persistence = ScenarioPersistence(rootDirectory: root.appending(path: "IntentLab", directoryHint: .isDirectory))
        let executor = XcodeTestExecutor(
            workDirectory: root.appending(path: "Executor", directoryHint: .isDirectory),
            persistence: persistence
        )
        let definition = try scenario()
        let invocation = invocation(for: definition)
        let activeJournal = journal(for: definition, invocation: invocation, phase: .running)
        let logURL = root.appending(path: "cancel.log")
        let processTask = Task {
            try await executor.runProcess(
                executable: "/bin/sleep",
                arguments: ["10"],
                logURL: logURL,
                invocationID: invocation.id,
                destinationIdentifier: invocation.destinationIdentifier,
                journal: activeJournal,
                appendLog: false,
                deadline: .seconds(15)
            )
        }

        let launchDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await executor.hasActiveExecution()) && ContinuousClock.now < launchDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await executor.hasActiveExecution())
        await #expect(throws: XcodeTestExecutorError.self) {
            try await executor.clearQuarantine(
                destinationIdentifier: invocation.destinationIdentifier,
                fixtureReadinessProven: true
            )
        }
        let cancelled = await executor.cancelActiveExecution(grace: .milliseconds(10))
        #expect(cancelled?.phase == .recoveryRequired)
        #expect(await executor.reservation(for: invocation.destinationIdentifier) != nil)
        do {
            _ = try await processTask.value
            Issue.record("The interrupted process unexpectedly completed.")
        } catch {
            #expect(error is XcodeTestExecutorError)
        }
        #expect(!(await executor.hasActiveExecution()))

        try await executor.clearQuarantine(
            destinationIdentifier: invocation.destinationIdentifier,
            fixtureReadinessProven: true
        )
        #expect(await executor.reservation(for: invocation.destinationIdentifier) == nil)
        let persisted = try await persistence.loadJournals()
        #expect(persisted.first(where: { $0.id == activeJournal.id })?.phase == .stopped)
    }

    @Test func requiredAssertionOutcomesIgnoreOptionalFailuresAndIncompleteExecution() throws {
        var definition = try scenario()
        definition.assertions = [
            ScenarioAssertion(
                kind: .returnedField, observationKey: "requiredValue",
                expectedValue: .string("approved"), explanation: "Required value matched.",
                required: true, applicableLanes: [.intentIntegration]
            ),
            ScenarioAssertion(
                kind: .returnedField, observationKey: "optionalValue",
                expectedValue: .string("preferred"), explanation: "Optional value matched.",
                required: false, applicableLanes: [.intentIntegration]
            ),
        ]

        func outcome(_ observations: [String: ScenarioValue], _ status: ScenarioExecutionStatus = .completed) -> ScenarioOutcome {
            ScenarioResultEvaluator.evaluate(
                definition: definition, lane: .intentIntegration,
                observations: observations, executionStatus: status
            ).0
        }

        #expect(outcome(["requiredValue": .string("approved")], .cancelled) == .notObserved)
        #expect(outcome([:]) == .failed)
        #expect(outcome(["requiredValue": .string("wrong")]) == .failed)
        #expect(outcome(["requiredValue": .string("approved")]) == .passed)
        #expect(outcome([
            "requiredValue": .string("approved"),
            "optionalValue": .string("wrong"),
        ]) == .passed)
    }

    @Test func semanticAssertionProducesNeedsReviewBeforeHostAssessment() throws {
        var definition = try scenario()
        definition.assertions = [ScenarioAssertion(
            kind: .semanticRubric,
            observationKey: "visibleResponse",
            explanation: "The response clearly confirms that the packing note opened."
        )]
        definition = try definition.frozen()

        let evaluated = ScenarioResultEvaluator.evaluate(
            definition: definition,
            lane: .siri,
            observations: ["visibleResponse": .string("Opened the packing note")],
            executionStatus: .completed
        )

        #expect(evaluated.0 == .needsReview)
        #expect(evaluated.1.count == 1)
        #expect(evaluated.1[0].observedValue == .string("Opened the packing note"))
        #expect(ScenarioResultEvaluator.evaluate(
            definition: definition, lane: .siri,
            observations: [:], executionStatus: .completed
        ).0 == .failed)

        var mixed = definition
        mixed.assertions.append(ScenarioAssertion(
            kind: .visibleText, observationKey: "approvedText",
            expectedValue: .string("approved"), explanation: "Visible text matched.",
            required: true, applicableLanes: [.siri]
        ))
        mixed = try mixed.frozen()
        #expect(ScenarioResultEvaluator.evaluate(
            definition: mixed, lane: .siri,
            observations: [
                "visibleResponse": .string("Opened the packing note"),
                "approvedText": .string("wrong"),
            ], executionStatus: .completed
        ).0 == .failed)
    }

    @Test func requiredLaneFailureOutranksEarlierIncompleteOrReviewLane() throws {
        let definition = try scenario()
        let now = Date()
        let failedSiri = ScenarioLaneResult(
            caseID: definition.id, attempt: 1, lane: .siri,
            executionStatus: .completed, outcome: .failed,
            startedAt: now, completedAt: now
        )
        let incompleteIntent = ScenarioLaneResult(
            caseID: definition.id, attempt: 1, lane: .intentIntegration,
            executionStatus: .cancelled, outcome: .notObserved,
            startedAt: now, completedAt: now
        )
        let reviewIntent = ScenarioLaneResult(
            caseID: definition.id, attempt: 1, lane: .intentIntegration,
            executionStatus: .completed, outcome: .needsReview,
            startedAt: now, completedAt: now
        )

        #expect(ScenarioResultEvaluator.overall(
            definition: definition, laneResults: [incompleteIntent, failedSiri]
        ) == .failed)
        #expect(ScenarioResultEvaluator.overall(
            definition: definition, laneResults: [reviewIntent, failedSiri]
        ) == .failed)
    }

    @Test func diagnosticClaimsFeaturePassOnlyFromCompletedPassingEvidence() {
        let caseID = UUID()
        let now = Date()
        func lane(
            _ kind: ScenarioLane,
            _ status: ScenarioExecutionStatus,
            _ outcome: ScenarioOutcome
        ) -> ScenarioLaneResult {
            .init(
                caseID: caseID, attempt: 1, lane: kind,
                executionStatus: status, outcome: outcome,
                startedAt: now, completedAt: now
            )
        }

        let failedIntent = lane(.intentIntegration, .completed, .failed)
        let noFeatureSummary = "The direct intent failed. No completed passing feature control is available, so the evidence does not establish where the failure arose."
        #expect(ScenarioDiagnosticClassifier.message(for: [failedIntent]) == noFeatureSummary)
        #expect(ScenarioDiagnosticClassifier.message(for: [
            lane(.appFeature, .timedOut, .notObserved), failedIntent
        ]) == noFeatureSummary)
        #expect(ScenarioDiagnosticClassifier.message(for: [
            lane(.appFeature, .completed, .needsReview), failedIntent
        ]) == noFeatureSummary)
        #expect(ScenarioDiagnosticClassifier.message(for: [
            lane(.appFeature, .timedOut, .passed), failedIntent
        ]) == noFeatureSummary)
        #expect(ScenarioDiagnosticClassifier.message(for: [
            lane(.appFeature, .timedOut, .failed), failedIntent
        ]) == noFeatureSummary)

        #expect(ScenarioDiagnosticClassifier.message(for: [
            lane(.appFeature, .completed, .passed), failedIntent
        ]) == "The feature control passed, but the direct intent returned a wrong or incomplete observable result. An application integration or mapping failure is observed.")
        #expect(ScenarioDiagnosticClassifier.message(for: [
            lane(.appFeature, .completed, .failed), failedIntent
        ]) == "The production feature and direct intent failed similarly. Investigate the application feature first; this evidence does not attribute the failure to Siri.")
    }

    @Test func optionalFeatureFailureDoesNotFailRequiredIntentAndSiriLanes() throws {
        let definition = try scenario()
        let now = Date()
        let failedFeature = ScenarioLaneResult(
            caseID: definition.id, attempt: 1, lane: .appFeature,
            executionStatus: .completed, outcome: .failed,
            startedAt: now, completedAt: now
        )
        let passedIntent = ScenarioLaneResult(
            caseID: definition.id, attempt: 1, lane: .intentIntegration,
            executionStatus: .completed, outcome: .passed,
            startedAt: now, completedAt: now
        )
        let passedSiri = ScenarioLaneResult(
            caseID: definition.id, attempt: 1, lane: .siri,
            executionStatus: .completed, outcome: .passed,
            startedAt: now, completedAt: now
        )

        #expect(ScenarioResultEvaluator.overall(
            definition: definition,
            laneResults: [failedFeature, passedIntent, passedSiri]
        ) == .passed)
    }

    @Test func requiredAssertionInsideOptionalFeatureLaneDoesNotBlockRelease() throws {
        var definition = try scenario()
        let featureAssertion = ScenarioAssertion(
            kind: .returnedField,
            observationKey: "feature.passRate",
            expectedValue: .number(1),
            explanation: "The linked feature run passed.",
            required: true,
            applicableLanes: [.appFeature]
        )
        definition.assertions.append(featureAssertion)
        definition = try definition.frozen()
        let invocation = invocation(for: definition)
        let envelope = evidence(for: definition, invocation: invocation)
        var ledger = ScenarioImportLedger()
        var run = try XCTestEvidenceImporter().importEvidence(
            data: try encoder.encode(envelope), definition: definition,
            journal: journal(for: definition, invocation: invocation, phase: .stopped),
            artifactRoot: try temporaryDirectory(), ledger: &ledger
        )
        let now = Date()
        run.laneResults.append(.init(
            caseID: definition.id,
            attempt: 1,
            lane: .appFeature,
            executionStatus: .completed,
            outcome: .failed,
            startedAt: now,
            completedAt: now,
            observations: ["feature.passRate": .number(0)],
            assertionResults: [.init(
                assertionID: featureAssertion.id,
                passed: false,
                observedValue: .number(0),
                message: "Feature pass rate was zero."
            )]
        ))
        run.outcome = ScenarioResultEvaluator.overall(definition: definition, laneResults: run.laneResults)
        run.xctestExitCode = 0

        #expect(run.outcome == .passed)
        #expect(ScenarioReleaseCheckEvaluator.report(definition: definition, run: run).outcome == .passed)
    }

    @Test func unscopedAssertionsDoNotApplyToFeatureControlEvidence() throws {
        let definition = try scenario()
        let evaluated = ScenarioResultEvaluator.evaluate(
            definition: definition,
            lane: .appFeature,
            observations: ["feature.runID": .string(UUID().uuidString)],
            executionStatus: .completed
        )

        #expect(evaluated.0 == .passed)
        #expect(evaluated.1.isEmpty)
    }

    @Test func importerAcceptsFeatureControlWithoutUnscopedScenarioAssertions() throws {
        let definition = try scenario()
        let invocation = invocation(for: definition)
        let envelope = evidence(for: definition, invocation: invocation)
        let now = Date()
        let feature = ScenarioLaneResult(
            caseID: definition.id,
            attempt: 1,
            lane: .appFeature,
            executionStatus: .completed,
            outcome: .passed,
            startedAt: now,
            completedAt: now,
            observations: ["feature.runID": .string(UUID().uuidString)]
        )
        var ledger = ScenarioImportLedger()

        let run = try XCTestEvidenceImporter().importEvidence(
            data: try encoder.encode(envelope),
            definition: definition,
            journal: journal(for: definition, invocation: invocation, phase: .stopped),
            artifactRoot: try temporaryDirectory(),
            ledger: &ledger,
            supplementaryResults: [feature]
        )

        #expect(run.laneResults.first(where: { $0.lane == .appFeature })?.outcome == .passed)
        #expect(run.outcome == .passed)
    }

    @Test func optionalAssertionFailureDoesNotBlockRelease() throws {
        var definition = try scenario()
        let optional = ScenarioAssertion(
            kind: .visibleText,
            observationKey: "subtitle",
            expectedValue: .string("Optional copy"),
            explanation: "Optional presentation copy remains visible.",
            required: false,
            applicableLanes: [.intentIntegration]
        )
        definition.assertions.append(optional)
        definition = try definition.frozen()
        let invocation = invocation(for: definition)
        var ledger = ScenarioImportLedger()
        let envelope = evidence(for: definition, invocation: invocation)
        var run = try XCTestEvidenceImporter().importEvidence(
            data: try encoder.encode(envelope), definition: definition,
            journal: journal(for: definition, invocation: invocation, phase: .stopped),
            artifactRoot: try temporaryDirectory(), ledger: &ledger
        )
        for index in run.laneResults.indices where run.laneResults[index].lane == .intentIntegration {
            run.laneResults[index].assertionResults.removeAll { $0.assertionID == optional.id }
            run.laneResults[index].assertionResults.append(.init(
                assertionID: optional.id,
                passed: false,
                message: "Optional copy differed."
            ))
        }

        run.xctestExitCode = 0

        #expect(ScenarioReleaseCheckEvaluator.report(definition: definition, run: run).outcome == .passed)
    }

    private func scenario() throws -> ScenarioDefinition {
        var value = ScenarioDefinition.starter()
        value.target.destinationIdentifier = "physical-device-1"
        return try value.frozen()
    }

    private func reusableBasicScenario() throws -> ScenarioDefinition {
        var value = try scenario()
        value.schemaVersion = ScenarioDefinition.reusableSchemaVersion
        value.goal.requestText = ""
        value.goal.languageCode = ""
        value.goal.expectedBehavior = ""
        value.fixture = .init(
            id: "", version: "", digest: "", isSynthetic: false,
            preparationOperation: "", cleanupOperation: ""
        )
        value.assertions = []
        value.directControl.outputFields = []
        value.coverage.appFeature = .notApplicable
        value.coverage.siri = .notApplicable
        value.purpose = .exploratory
        value.checkMode = .basic
        value.requiredClaims = [.executionCompleted]
        value.observationPlan = []
        value.integration = .init(id: "tasks", version: "1.0", digest: String(repeating: "a", count: 64))
        return try value.frozen()
    }

    private func reusableInvocation(for definition: ScenarioDefinition) -> ScenarioInvocationIdentity {
        var value = invocation(for: definition)
        value.harnessVersion = ScenarioInvocationIdentity.reusableHarnessVersion
        value.integration = definition.integration
        value.requiredCapabilities = ScenarioHarnessCapabilities.required(for: definition).sorted()
        return value
    }

    private func invocation(for definition: ScenarioDefinition) -> ScenarioInvocationIdentity {
        let app = ScenarioProductIdentity(bundleIdentifier: definition.target.bundleIdentifier, executableName: "Fixture", sha256: "app-sha")
        let test = ScenarioProductIdentity(bundleIdentifier: "com.example.IntentLabFixtureUITests", executableName: "FixtureUITests", sha256: "test-sha")
        return .init(
            id: UUID(), nonce: UUID().uuidString, issuedAt: .now,
            testIdentity: .init(bundleIdentifier: test.bundleIdentifier, className: "IntentLabScenarioTests", methodName: "testIntentLabScenario"),
            harnessVersion: ScenarioInvocationIdentity.currentHarnessVersion,
            destinationIdentifier: definition.target.destinationIdentifier,
            scenarioDigest: definition.definitionDigest, resultBundleIdentity: UUID().uuidString,
            appProduct: app, testProduct: test
        )
    }

    private func evidence(for definition: ScenarioDefinition, invocation: ScenarioInvocationIdentity) -> ScenarioEvidenceEnvelope {
        let observations = Dictionary(uniqueKeysWithValues: definition.assertions.compactMap { assertion in
            assertion.expectedValue.map { (assertion.observationKey, $0) }
        })
        let assertionResults = definition.assertions.map {
            ScenarioAssertionResult(assertionID: $0.id, passed: true, observedValue: $0.expectedValue, message: "matched")
        }
        let now = Date()
        var lanes: [ScenarioLaneResult] = [
            .init(caseID: definition.id, attempt: 1, lane: .intentIntegration, executionStatus: .completed,
                  outcome: .passed, startedAt: now, completedAt: now,
                  observations: observations, assertionResults: assertionResults),
        ]
        for attempt in 1...(definition.coverage.siriAttemptCount ?? 3) {
            lanes.append(.init(
                caseID: definition.id, attempt: attempt, lane: .siri,
                executionStatus: .completed, outcome: .passed,
                startedAt: now, completedAt: now,
                observations: observations, assertionResults: assertionResults
            ))
        }
        var envelope = ScenarioEvidenceEnvelope(
            invocation: invocation, sourceBundleIdentifier: definition.target.bundleIdentifier,
            observedAppProduct: invocation.appProduct!, observedTestProduct: invocation.testProduct!,
            environment: .init(
                xcodeVersion: "27.0", sdkVersion: "27.0", deviceModel: "iPhone",
                operatingSystem: "iOS 27.0", operatingSystemBuild: "24A", languageCode: "en-GB",
                regionCode: "GB", timeZoneIdentifier: "Europe/London", siriConfiguration: "enabled",
                siriConfigurationSource: .manuallySupplied, executedAt: now
            ),
            testCount: 1, results: lanes
        )
        if definition.schemaVersion == ScenarioDefinition.reusableSchemaVersion {
            envelope.schemaVersion = ScenarioEvidenceEnvelope.reusableSchemaVersion
            envelope.integration = definition.integration
            envelope.runnerPackageVersion = "0.1.0"
            envelope.negotiatedCapabilities = ScenarioHarnessCapabilities.required(for: definition).sorted()
            envelope.results = envelope.results.map { result in
                var result = result
                result.claims = [.executionCompleted]
                return result
            }
        }
        return envelope
    }

    private func journal(
        for definition: ScenarioDefinition,
        invocation: ScenarioInvocationIdentity,
        phase: ScenarioExecutorPhase
    ) -> ScenarioExecutionJournal {
        .init(
            phase: phase, invocation: invocation, scenarioID: definition.id,
            scenarioVersion: definition.version, resultBundlePath: "/tmp/result.xcresult",
            derivedDataPath: "/tmp/derived", buildLogPath: "/tmp/build.log",
            intendedExecutable: "/usr/bin/xcodebuild", intendedArguments: [],
            processIdentifier: nil, processStartedAt: nil, updatedAt: .now, recoveryReason: nil
        )
    }

    private func expectRejected(
        _ envelope: ScenarioEvidenceEnvelope,
        definition: ScenarioDefinition,
        journal: ScenarioExecutionJournal,
        root: URL,
        importer: XCTestEvidenceImporter
    ) throws {
        var ledger = ScenarioImportLedger()
        #expect(throws: ScenarioEvidenceImportError.self) {
            _ = try importer.importEvidence(
                data: try encoder.encode(envelope), definition: definition,
                journal: journal, artifactRoot: root, ledger: &ledger
            )
        }
        #expect(ledger == ScenarioImportLedger())
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var encoder: JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.sortedKeys]
        return value
    }

    private var decoder: JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }
}
