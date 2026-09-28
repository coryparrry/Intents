import Foundation
import Testing
@testable import FoundationEvals

struct IntentLabProjectInstallerTests {
    @Test func generatedBasicDeclarationCannotClaimStableFixtureProof() throws {
        let basic = try IntentLabProjectInstaller.validateDeclaration(
            Fixture.declarationData,
            targetBundleIdentifier: "com.example.Consumer", testTargetName: "UITests"
        )
        #expect(!basic.hasFixtureContentObserver)
        var declaration = try #require(JSONSerialization.jsonObject(with: Fixture.declarationData) as? [String: Any])
        declaration["observers"] = [["id": "summarySourceContentDigest"]]
        let owned = try IntentLabProjectInstaller.validateDeclaration(
            JSONSerialization.data(withJSONObject: declaration),
            targetBundleIdentifier: "com.example.Consumer", testTargetName: "UITests"
        )
        #expect(owned.hasFixtureContentObserver)
    }

    private struct Fixture {
        static let declarationData = Data("""
        {"schemaVersion":1,"id":"consumer-test","version":"1","targetBundleIdentifier":"com.example.Consumer","projectIdentity":"Consumer","targetIdentity":"UITests","supportedHarnessProtocols":["intent-lab-v2"],"actions":[],"resultProjections":[],"preparationOperations":[],"observers":[],"isolation":{"kind":"readOnly"},"capabilities":["direct-intent-execution","environment-payload"]}
        """.utf8)
        let root: URL
        let project: URL
        let package: URL
        let applicationID: String
        let uiTestID: String

        init(pathPrefix: String = "IntentLabInstallerTests") throws {
            let fileManager = FileManager.default
            root = fileManager.temporaryDirectory.appending(path: "\(pathPrefix)-\(UUID().uuidString)")
            project = root.appending(path: "Consumer.xcodeproj")
            package = root.appending(path: "Package")
            try fileManager.createDirectory(at: project.appending(path: "xcshareddata/xcschemes"), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: package, withIntermediateDirectories: true)
            let repositoryProject = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "FoundationEvals.xcodeproj")
            try fileManager.copyItem(at: repositoryProject.appending(path: "project.pbxproj"),
                                     to: project.appending(path: "project.pbxproj"))
            try fileManager.copyItem(at: repositoryProject.appending(path: "xcshareddata/xcschemes/FoundationEvals.xcscheme"),
                                     to: project.appending(path: "xcshareddata/xcschemes/FoundationEvals.xcscheme"))
            let data = try Data(contentsOf: project.appending(path: "project.pbxproj"))
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
            let objects = plist["objects"] as! [String: [String: Any]]
            applicationID = objects.first { $0.value["productType"] as? String == "com.apple.product-type.application" }!.key
            uiTestID = objects.first { $0.value["productType"] as? String == "com.apple.product-type.bundle.ui-testing" }!.key
        }

        func request(existingTarget: Bool = true, workspaceURL: URL? = nil,
                     consumerSource: String = "import XCTest\nfinal class IntentLabScenarioTests: XCTestCase {}\n") -> IntentLabInstallationRequest {
            .init(projectURL: project, workspaceURL: workspaceURL,
                  scheme: "FoundationEvals", applicationTargetID: applicationID,
                  uiTestTargetID: existingTarget ? uiTestID : nil, packageURL: package,
                  packageProduct: "IntentLabTesting",
                  consumerSource: consumerSource,
                  declarationData: Self.declarationData)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        func makeWorkspace(copyScheme: Bool) throws -> URL {
            let workspace = root.appending(path: "Consumer.xcworkspace")
            try FileManager.default.createDirectory(at: workspace.appending(path: "xcshareddata/xcschemes"),
                                                    withIntermediateDirectories: true)
            try Data("<Workspace version=\"1.0\"><FileRef location=\"group:Consumer.xcodeproj\"/></Workspace>".utf8)
                .write(to: workspace.appending(path: "contents.xcworkspacedata"))
            if copyScheme {
                try FileManager.default.copyItem(
                    at: project.appending(path: "xcshareddata/xcschemes/FoundationEvals.xcscheme"),
                    to: workspace.appending(path: "xcshareddata/xcschemes/FoundationEvals.xcscheme"))
                let url = workspace.appending(path: "xcshareddata/xcschemes/FoundationEvals.xcscheme")
                let xml = try XMLDocument(data: Data(contentsOf: url))
                for node in try xml.nodes(forXPath: "//BuildableReference") {
                    (node as? XMLElement)?.attribute(forName: "ReferencedContainer")?.stringValue = "container:Consumer.xcodeproj"
                }
                try xml.xmlData(options: [.nodePrettyPrint]).write(to: url)
            }
            return workspace
        }
    }

    private struct FixtureCommandFailure: LocalizedError {
        let executable: URL
        let arguments: [String]
        let output: String
        let exitCode: Int32

        var errorDescription: String? {
            "\(executable.lastPathComponent) exited with code \(exitCode): \(arguments.joined(separator: " "))\n\(output)"
        }
    }

    private static func executable(named name: String) -> URL? {
        let fileManager = FileManager.default
        for directory in ProcessInfo.processInfo.environment["PATH", default: ""].split(separator: ":") {
            let candidate = URL(filePath: String(directory)).appending(path: name)
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func run(_ executable: URL, arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw FixtureCommandFailure(executable: executable, arguments: arguments,
                                        output: text, exitCode: process.terminationStatus)
        }
        return text
    }

    @Test func existingTargetRoundTripAndIdempotence() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let installer = IntentLabProjectInstaller()
        let request = fixture.request()
        let original = try Data(contentsOf: fixture.project.appending(path: "project.pbxproj"))
        let preview = try installer.preview(request)
        #expect(preview.supported)
        #expect(preview.changes.count == 5)
        #expect(preview.changes.first { $0.url.lastPathComponent == "IntentLabScenarioTests.swift" }?.previous == nil)
        #expect(preview.changes.first { $0.url.lastPathComponent == "IntentLabIntegration.json" }?.previous == nil)
        let adapter = try #require(preview.changes.first { $0.url.lastPathComponent == "IntentLabAppAdapter.swift" })
        let scaffold = String(decoding: adapter.proposed, as: UTF8.self)
        #expect(scaffold.contains("throw IntentLabIntegrationError.unsupportedPreparation"))
        #expect(scaffold.contains("throw IntentLabAppAdapterError.unimplementedObservation"))
        #expect(!scaffold.contains("expectedValue"))
        #expect(!scaffold.contains("return [:]"))
        #expect(preview.changes.allSatisfy { $0.afterDigest != $0.beforeDigest })
        let receipt = try installer.apply(preview)
        #expect(receipt.changedFiles.count == 5)
        let verification = try installer.verify(request)
        #expect(verification.installed, "Missing: \(verification.missing)")
        #expect(try installer.preview(request).changes.isEmpty)
        #expect(try installer.repair(request).alreadyInstalled)
        let installed = try Data(contentsOf: fixture.project.appending(path: "project.pbxproj"))
        #expect(installed.starts(with: Data(original.prefix(80))))
        let plist = try PropertyListSerialization.propertyList(from: installed, format: nil) as! [String: Any]
        let objects = plist["objects"] as! [String: [String: Any]]
        let target = objects[fixture.uiTestID]!
        let productNames = (target["packageProductDependencies"] as? [String] ?? [])
            .compactMap { objects[$0]?["productName"] as? String }
        #expect(productNames.contains("IntentLabTesting"))
        #expect(productNames.contains("IntentLabContracts"))
        let listID = target["buildConfigurationList"] as! String
        let configIDs = objects[listID]!["buildConfigurations"] as! [String]
        for configID in configIDs {
            let settings = objects[configID]!["buildSettings"] as! [String: Any]
            #expect(settings["INTENT_LAB_HARNESS_VERSION"] as? String == "intent-lab-v2")
            #expect((settings["INTENT_LAB_HARNESS_CAPABILITIES"] as? String)?.contains("direct-intent-execution") == true)
        }
    }

    @Test func coreTestingInstallsTheSiriOnlyProductsAndScaffold() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var declaration = try #require(JSONSerialization.jsonObject(with: Fixture.declarationData) as? [String: Any])
        declaration["capabilities"] = ["environment-payload", "preparation", "accessible-result", "siri", "siri-completion"]
        declaration["observers"] = [[
            "id": "visibleSiriState", "source": "uiElement", "selector": "intent-lab-visible-state",
            "type": ["primitive": ["_0": "string"]]
        ]]
        let source = """
        import IntentLabCoreTesting
        import XCTest

        @available(iOS 27.0, *)
        @MainActor
        final class IntentLabScenarioTests: XCTestCase {
            func testIntentLabScenario() throws {
                try IntentLabSiriScenarioRunner.run(testCase: self, integration: IntentLabAppAdapter())
            }
            func testIntentLabConnection() throws {
                try IntentLabSiriScenarioRunner.checkConnection(testCase: self, integration: IntentLabAppAdapter())
            }
        }
        """
        let request = IntentLabInstallationRequest(
            projectURL: fixture.project, scheme: "FoundationEvals",
            applicationTargetID: fixture.applicationID, uiTestTargetID: fixture.uiTestID,
            packageURL: fixture.package, packageProduct: "IntentLabCoreTesting",
            consumerSource: source,
            declarationData: try JSONSerialization.data(withJSONObject: declaration))
        let plan = try IntentLabProjectInstaller().preview(request)
        #expect(plan.supported)
        let projectChange = try #require(plan.changes.first { $0.url.lastPathComponent == "project.pbxproj" })
        let root = try PropertyListSerialization.propertyList(from: projectChange.proposed, format: nil) as! [String: Any]
        let objects = root["objects"] as! [String: [String: Any]]
        let target = try #require(objects[fixture.uiTestID])
        let productNames = (target["packageProductDependencies"] as? [String] ?? [])
            .compactMap { objects[$0]?["productName"] as? String }
        #expect(Set(productNames) == ["IntentLabCoreTesting", "IntentLabContracts"])
        #expect(!productNames.contains("IntentLabTesting"))
        #expect(source.contains("IntentLabSiriScenarioRunner.run"))
        #expect(source.contains("IntentLabSiriScenarioRunner.checkConnection"))
        let scaffold = String(decoding: try #require(plan.changes.first {
            $0.url.lastPathComponent == "IntentLabAppAdapter.swift"
        }).proposed, as: UTF8.self)
        #expect(scaffold.contains("import IntentLabCoreTesting"))
        #expect(scaffold.contains("IntentLabSiriIntegration"))
        #expect(!scaffold.contains("import IntentLabTesting"))
    }

    @Test func coreTestingRequiresSiriSourceContractAndRejectsDirectCapabilities() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = "import IntentLabCoreTesting\nIntentLabSiriScenarioRunner.run"
        let base = IntentLabInstallationRequest(
            projectURL: fixture.project, scheme: "FoundationEvals",
            applicationTargetID: fixture.applicationID, uiTestTargetID: fixture.uiTestID,
            packageURL: fixture.package, packageProduct: "IntentLabCoreTesting",
            consumerSource: source, declarationData: Fixture.declarationData)
        let missingSiri = try IntentLabProjectInstaller().preview(.init(
            projectURL: base.projectURL, workspaceURL: base.workspaceURL, scheme: base.scheme,
            applicationTargetID: base.applicationTargetID, uiTestTargetID: base.uiTestTargetID,
            packageURL: base.packageURL, packageProduct: base.packageProduct,
            consumerSource: "import IntentLabCoreTesting\nIntentLabScenarioRunner.run",
            declarationData: Fixture.declarationData))
        #expect(!missingSiri.supported)
        #expect(missingSiri.manualSteps.first?.contains("IntentLabSiriScenarioRunner") == true)

        var declaration = try #require(JSONSerialization.jsonObject(with: Fixture.declarationData) as? [String: Any])
        declaration["capabilities"] = ["environment-payload", "direct-intent-execution", "siri"]
        let directRequest = IntentLabInstallationRequest(
            projectURL: fixture.project, scheme: "FoundationEvals",
            applicationTargetID: fixture.applicationID, uiTestTargetID: fixture.uiTestID,
            packageURL: fixture.package, packageProduct: "IntentLabCoreTesting",
            consumerSource: source,
            declarationData: try JSONSerialization.data(withJSONObject: declaration))
        let direct = try IntentLabProjectInstaller().preview(directRequest)
        #expect(!direct.supported)
        #expect(direct.manualSteps.first?.contains("Siri-only") == true)
    }

    @Test func coreTestingRequiresTypedAppOwnedSiriStateObserver() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var declaration = try #require(JSONSerialization.jsonObject(with: Fixture.declarationData) as? [String: Any])
        declaration["capabilities"] = ["environment-payload", "preparation", "accessible-result", "siri", "siri-completion"]
        let request = IntentLabInstallationRequest(
            projectURL: fixture.project, scheme: "FoundationEvals",
            applicationTargetID: fixture.applicationID, uiTestTargetID: fixture.uiTestID,
            packageURL: fixture.package, packageProduct: "IntentLabCoreTesting",
            consumerSource: "import IntentLabCoreTesting\nIntentLabSiriScenarioRunner.run",
            declarationData: try JSONSerialization.data(withJSONObject: declaration))
        let plan = try IntentLabProjectInstaller().preview(request)
        #expect(!plan.supported)
        #expect(plan.changes.isEmpty)
        #expect(plan.manualSteps.first?.contains("typed app-owned observer") == true)
        #expect(plan.manualFiles.contains { $0.filename == "IntentLabAppAdapter.swift" })
    }

    @Test func coreTestingRequiresItsOwnPublishedRevision() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var declaration = try #require(JSONSerialization.jsonObject(with: Fixture.declarationData) as? [String: Any])
        declaration["capabilities"] = ["environment-payload", "preparation", "accessible-result", "siri", "siri-completion"]
        declaration["observers"] = [[
            "id": "visibleSiriState", "source": "uiElement", "selector": "intent-lab-visible-state",
            "type": ["primitive": ["_0": "string"]]
        ]]
        let declarationData = try JSONSerialization.data(withJSONObject: declaration)
        let consumerSource = "import IntentLabCoreTesting\nIntentLabSiriScenarioRunner.run"
        let request = IntentLabInstallationRequest(
            projectURL: fixture.project, scheme: "FoundationEvals",
            applicationTargetID: fixture.applicationID, uiTestTargetID: fixture.uiTestID,
            packageURL: IntentLabPackageRevisionManifest.packageURL,
            packageProduct: "IntentLabCoreTesting", consumerSource: consumerSource,
            declarationData: declarationData)
        #expect(request.packageRevision == nil)
        let plan = try IntentLabProjectInstaller().preview(request)
        #expect(!plan.supported)
        #expect(plan.manualSteps.first?.contains("published exact 40-character revision") == true)

        let explicitRevision = String(repeating: "c", count: 40)
        let explicitlyPinned = IntentLabInstallationRequest(
            projectURL: fixture.project, scheme: "FoundationEvals",
            applicationTargetID: fixture.applicationID, uiTestTargetID: fixture.uiTestID,
            packageURL: IntentLabPackageRevisionManifest.packageURL,
            packageRevision: explicitRevision, packageProduct: "IntentLabCoreTesting",
            consumerSource: consumerSource, declarationData: declarationData)
        #expect(explicitlyPinned.packageRevision == explicitRevision)
        #expect(try IntentLabProjectInstaller().preview(explicitlyPinned).supported)
    }

    @Test func createsDedicatedTargetAndSchemeEntry() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let installer = IntentLabProjectInstaller()
        let request = fixture.request(existingTarget: false)
        let preview = try installer.preview(request)
        #expect(preview.supported)
        #expect(preview.targetName == "IntentLabUITests")
        _ = try installer.apply(preview)
        #expect(try installer.verify(request).installed)
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: fixture.project.appending(path: "project.pbxproj")), format: nil) as! [String: Any]
        let objects = plist["objects"] as! [String: [String: Any]]
        #expect(objects.values.contains { $0["name"] as? String == "IntentLabUITests" })
        let scheme = try XMLDocument(data: Data(contentsOf: fixture.project.appending(path: "xcshareddata/xcschemes/FoundationEvals.xcscheme")))
        #expect(scheme.xmlString.contains("IntentLabUITests.xctest"))
        let testBuild = try #require((scheme.nodes(forXPath: "//BuildActionEntry") as? [XMLElement])?.first {
            $0.elements(forName: "BuildableReference").first?
                .attribute(forName: "BuildableName")?.stringValue == "IntentLabUITests.xctest"
        })
        #expect(testBuild.attribute(forName: "buildForTesting")?.stringValue == "YES")
        #expect(testBuild.attribute(forName: "buildForArchiving")?.stringValue == "NO")
    }

    @Test func generatedUITestTargetMatchesSelectedMacOSApp() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = """
        import XCTest
        import IntentLabTesting
        @available(macOS 27.0, iOS 27.0, *)
        @MainActor final class IntentLabScenarioTests: XCTestCase {}
        """
        let plan = try IntentLabProjectInstaller().preview(
            fixture.request(existingTarget: false, consumerSource: source))
        #expect(plan.supported)
        let projectChange = try #require(plan.changes.first { $0.url.lastPathComponent == "project.pbxproj" })
        let root = try PropertyListSerialization.propertyList(from: projectChange.proposed, format: nil) as! [String: Any]
        let objects = root["objects"] as! [String: [String: Any]]
        let target = try #require(objects.values.first { $0["name"] as? String == "IntentLabUITests" })
        let configList = try #require(objects[target["buildConfigurationList"] as! String])
        let configIDs = configList["buildConfigurations"] as! [String]
        #expect(!configIDs.isEmpty)
        for configID in configIDs {
            let settings = objects[configID]!["buildSettings"] as! [String: Any]
            #expect(settings["SDKROOT"] as? String == "macosx")
            #expect(settings["SUPPORTED_PLATFORMS"] as? String == "macosx")
            #expect(settings["MACOSX_DEPLOYMENT_TARGET"] as? String == "27.0")
            #expect(settings["IPHONEOS_DEPLOYMENT_TARGET"] == nil)
        }
        let sourceChange = try #require(plan.changes.first { $0.url.lastPathComponent == "IntentLabScenarioTests.swift" })
        #expect(String(decoding: sourceChange.proposed, as: UTF8.self).contains("@available(macOS 27.0, iOS 27.0, *)"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["INTENT_LAB_RUN_MAC_INSTALLER_BUILD_TEST"] == "1"))
    func generatedMacUITestTargetBuildsWithXcode() throws {
        // This integration lane is opt-in so the portable suite needs no XcodeGen.
        let xcodegen = try #require(Self.executable(named: "xcodegen"))
        let xcodebuild = try #require(Self.executable(named: "xcodebuild"))
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(path: "IntentLabMacBuildFixture-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let sources = root.appending(path: "Sources")
        let specDirectory = root.appending(path: "ProjectSpec")
        try fileManager.createDirectory(at: sources, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: specDirectory, withIntermediateDirectories: true)
        try Data("""
        import SwiftUI

        @main
        struct IntentLabMacFixtureApp: App {
            var body: some Scene {
                WindowGroup { Text("Intent Lab installer fixture") }
            }
        }
        """.utf8).write(to: sources.appending(path: "IntentLabMacFixtureApp.swift"))
        let spec = """
        name: IntentLabMacInstallerFixture
        options:
          deploymentTarget:
            macOS: "27.0"
        settings:
          base:
            GENERATE_INFOPLIST_FILE: YES
            MACOSX_DEPLOYMENT_TARGET: "27.0"
            SDKROOT: macosx
            SUPPORTED_PLATFORMS: macosx
            SWIFT_VERSION: "6.0"
        targets:
          IntentLabMacInstallerFixture:
            type: application
            platform: macOS
            sources:
              - Sources
            settings:
              base:
                PRODUCT_BUNDLE_IDENTIFIER: com.example.IntentLabMacInstallerFixture
        schemes:
          IntentLabMacInstallerFixture:
            build:
              targets:
                IntentLabMacInstallerFixture: all
            run:
              config: Debug
            test:
              config: Debug
        """
        let specURL = specDirectory.appending(path: "project.yml")
        try Data(spec.utf8).write(to: specURL)
        _ = try Self.run(xcodegen, arguments: [
            "generate", "--spec", specURL.path, "--project", root.path, "--project-root", root.path
        ], in: root)

        let project = root.appending(path: "IntentLabMacInstallerFixture.xcodeproj")
        let inspection = try IntentLabProjectInstaller.inspect(projectURL: project)
        let appTarget = try #require(inspection.applications.first)
        #expect(inspection.sharedSchemes.contains("IntentLabMacInstallerFixture"))
        let bundleIdentifier = "com.example.IntentLabMacInstallerFixture"
        let declaration: [String: Any] = [
            "schemaVersion": 1,
            "id": "\(bundleIdentifier).intentlab",
            "version": "1",
            "targetBundleIdentifier": bundleIdentifier,
            "projectIdentity": project.lastPathComponent,
            "targetIdentity": "IntentLabUITests",
            "supportedHarnessProtocols": ["intent-lab-v2"],
            "actions": [["id": "fixtureIntent", "parameters": []]],
            "resultProjections": [],
            "preparationOperations": ["none"],
            "observers": [],
            "isolation": ["kind": "readOnly"],
            "capabilities": ["direct-intent-execution", "environment-payload"],
        ]
        let consumerSource = """
        import XCTest
        import IntentLabTesting

        @available(macOS 27.0, iOS 27.0, *)
        @MainActor
        final class IntentLabScenarioTests: XCTestCase {
            func testIntentLabScenario() throws {
                try IntentLabScenarioRunner.run(testCase: self, integration: IntentLabBasicIntegration())
            }

            func testIntentLabConnection() throws {
                try IntentLabScenarioRunner.checkConnection(testCase: self, integration: IntentLabBasicIntegration())
            }
        }
        """
        let packageURL = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let request = IntentLabInstallationRequest(
            projectURL: project, scheme: "IntentLabMacInstallerFixture",
            applicationTargetID: appTarget.id, packageURL: packageURL,
            packageProduct: "IntentLabTesting", consumerSource: consumerSource,
            declarationData: try JSONSerialization.data(withJSONObject: declaration, options: [.sortedKeys]))
        let installer = IntentLabProjectInstaller()
        let plan = try installer.preview(request)
        #expect(plan.supported, "\(plan.manualSteps)")
        _ = try installer.apply(plan)
        let verification = try installer.verify(request)
        #expect(verification.installed, "Missing: \(verification.missing)")
        _ = try Self.run(xcodebuild, arguments: [
            "build-for-testing", "-project", project.path,
            "-scheme", "IntentLabMacInstallerFixture",
            "-destination", "platform=macOS",
            "-derivedDataPath", root.appending(path: "DerivedData").path,
            "CODE_SIGNING_ALLOWED=NO", "-quiet",
        ], in: root)
    }

    @Test func unsupportedAppPlatformGetsManualGuidance() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let pbxURL = fixture.project.appending(path: "project.pbxproj")
        var document = try OpenStepProjectDocument(Data(contentsOf: pbxURL))
        let root = try PropertyListSerialization.propertyList(from: document.data, format: nil) as! [String: Any]
        let objects = root["objects"] as! [String: [String: Any]]
        let app = objects[fixture.applicationID]!
        let listID = app["buildConfigurationList"] as! String
        let configIDs = objects[listID]!["buildConfigurations"] as! [String]
        for configID in configIDs {
            for (key, value) in [("SDKROOT", "xros"),
                                 ("SUPPORTED_PLATFORMS", "\"xros xrsimulator\""),
                                 ("XROS_DEPLOYMENT_TARGET", "27.0")] {
                let settings = try document.object(configID).dictionary!["buildSettings"]!
                try document.setKey(key, value: value, in: settings)
            }
        }
        try document.data.write(to: pbxURL)
        let plan = try IntentLabProjectInstaller().preview(fixture.request(existingTarget: false))
        #expect(!plan.supported)
        #expect(plan.manualSteps.first?.contains("supports iOS and macOS apps") == true)
    }

    @Test func workspaceProjectIdentityDisambiguatesEqualBasenames() {
        let root = URL(filePath: "/tmp/IntentLabIdentity")
        let workspace = root.appending(path: "Combined.xcworkspace")
        let first = IntentLabProjectInstaller.declarationProjectIdentity(
            projectURL: root.appending(path: "First/Tasks.xcodeproj"), workspaceURL: workspace)
        let second = IntentLabProjectInstaller.declarationProjectIdentity(
            projectURL: root.appending(path: "Second/Tasks.xcodeproj"), workspaceURL: workspace)
        #expect(first == "First/Tasks.xcodeproj")
        #expect(second == "Second/Tasks.xcodeproj")
        #expect(first != second)
    }

    @Test func stalePreviewPreservesInterveningEdit() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let installer = IntentLabProjectInstaller()
        let preview = try installer.preview(fixture.request())
        let pbxURL = fixture.project.appending(path: "project.pbxproj")
        var changed = try Data(contentsOf: pbxURL)
        changed.append(Data("\n// developer edit\n".utf8))
        try changed.write(to: pbxURL)
        #expect(throws: IntentLabProjectInstallerError.self) { try installer.apply(preview) }
        #expect(try Data(contentsOf: pbxURL) == changed)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: ".intent-lab-install-journal.json").path))
    }

    @Test func previewTreatsUnreadableDeveloperFileAsManualReview() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let sourceURL = fixture.root.appending(path: "IntentLabIntegration/UITests/IntentLabScenarioTests.swift")
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("developer-owned test".utf8).write(to: sourceURL)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: sourceURL.path)
        let plan = try IntentLabProjectInstaller().preview(fixture.request())
        #expect(!plan.supported)
        #expect(plan.manualSteps.first?.contains("could not be read") == true, "\(plan.manualSteps)")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sourceURL.path)
        #expect(try Data(contentsOf: sourceURL) == Data("developer-owned test".utf8))
    }

    @Test func applyDoesNotTreatAnUnreadableNewFileAsMissing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let installer = IntentLabProjectInstaller()
        let plan = try installer.preview(fixture.request())
        let sourceChange = try #require(plan.changes.first { $0.url.lastPathComponent == "IntentLabScenarioTests.swift" })
        #expect(sourceChange.previous == nil)
        try FileManager.default.createDirectory(at: sourceChange.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: sourceChange.url.path,
                                                   withDestinationPath: "unavailable-source.swift")
        #expect(throws: IntentLabProjectInstallerError.self) { try installer.apply(plan) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: sourceChange.url.path) == "unavailable-source.swift")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: ".intent-lab-install-journal.json").path))
    }

    @Test func applyPreservesAFileCreatedAfterPreview() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let installer = IntentLabProjectInstaller()
        let plan = try installer.preview(fixture.request())
        let sourceChange = try #require(plan.changes.first { $0.url.lastPathComponent == "IntentLabScenarioTests.swift" })
        try FileManager.default.createDirectory(at: sourceChange.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let developerContent = Data("developer-owned test".utf8)
        try developerContent.write(to: sourceChange.url, options: .withoutOverwriting)
        #expect(throws: IntentLabProjectInstallerError.self) { try installer.apply(plan) }
        #expect(try Data(contentsOf: sourceChange.url) == developerContent)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: ".intent-lab-install-journal.json").path))
    }

    @Test func interruptedTransactionRecoveryPreservesLaterEdits() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let installer = IntentLabProjectInstaller()
        let plan = try installer.preview(fixture.request())
        let first = plan.changes[0]
        let journalURL = fixture.root.appending(path: ".intent-lab-install-journal.json")
        let journal = "{\"entries\":[{\"path\":\"\(first.url.path)\",\"before\":\"\(first.previous!.base64EncodedString())\",\"after\":\"\(first.proposed.base64EncodedString())\"}]}"
        try Data(journal.utf8).write(to: journalURL)
        try first.proposed.write(to: first.url)
        _ = try installer.recover(projectURL: fixture.project)
        #expect(try Data(contentsOf: first.url) == first.previous)
        try Data(journal.utf8).write(to: journalURL)
        try first.proposed.write(to: first.url)
        var userEdit = first.proposed
        userEdit.append(Data("\n// later edit\n".utf8))
        try userEdit.write(to: first.url)
        #expect(throws: IntentLabProjectInstallerError.self) { try installer.recover(projectURL: fixture.project) }
        #expect(try Data(contentsOf: first.url) == userEdit)
    }

    @Test func failedExclusiveInstallWriteKeepsJournalAndPartialFileForReview() throws {
        struct InjectedWriteFailure: Error {}
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let installer = IntentLabProjectInstaller()
        let plan = try installer.preview(fixture.request())
        #expect(plan.supported)
        let projectURL = fixture.project.appending(path: "project.pbxproj")
        let schemeURL = fixture.project.appending(
            path: "xcshareddata/xcschemes/FoundationEvals.xcscheme")
        let sourceURL = try #require(plan.changes.first {
            $0.url.lastPathComponent == "IntentLabScenarioTests.swift"
        }).url
        let originalProject = try Data(contentsOf: projectURL)
        let originalScheme = try Data(contentsOf: schemeURL)
        let partial = Data("partial source".utf8)
        #expect(throws: InjectedWriteFailure.self) {
            try installer.apply(plan, writeChange: { data, url, options in
                if url == sourceURL {
                    try partial.write(to: url, options: .withoutOverwriting)
                    throw InjectedWriteFailure()
                }
                try data.write(to: url, options: options)
            })
        }
        let journalURL = fixture.root.appending(path: ".intent-lab-install-journal.json")
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
        #expect(try Data(contentsOf: sourceURL) == partial)
        #expect(try Data(contentsOf: projectURL) == originalProject)
        #expect(try Data(contentsOf: schemeURL) == originalScheme)
        #expect(throws: IntentLabProjectInstallerError.self) {
            try installer.recover(projectURL: fixture.project)
        }
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
        try FileManager.default.removeItem(at: sourceURL)
        _ = try installer.recover(projectURL: fixture.project)
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
    }

    @Test func failedManualExportPreservesPartialFileAndRemovesExactEarlierOutput() throws {
        struct InjectedWriteFailure: Error {}
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("name: Consumer".utf8).write(to: fixture.root.appending(path: "project.yml"))
        let installer = IntentLabProjectInstaller()
        let plan = try installer.preview(fixture.request())
        #expect(!plan.supported)
        let output = fixture.root.appending(path: "Review")
        let partialURL = output.appending(path: "IntentLabIntegration.json")
        let partial = Data("partial declaration".utf8)
        #expect(throws: IntentLabProjectInstallerError.self) {
            try installer.exportManualFiles(plan, to: output, writeFile: { data, url in
                if url == partialURL {
                    try partial.write(to: url, options: .withoutOverwriting)
                    throw InjectedWriteFailure()
                }
                try data.write(to: url, options: .withoutOverwriting)
            })
        }
        #expect(try Data(contentsOf: partialURL) == partial)
        let earlier = try #require(plan.manualFiles.first).filename
        #expect(!FileManager.default.fileExists(atPath: output.appending(path: earlier).path))
        #expect(throws: IntentLabProjectInstallerError.self) {
            try installer.exportManualFiles(plan, to: output)
        }
        #expect(try Data(contentsOf: partialURL) == partial)
    }

    @Test func generatorManagedProjectOffersManualPath() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("name: Consumer".utf8).write(to: fixture.root.appending(path: "project.yml"))
        let installer = IntentLabProjectInstaller()
        let plan = try installer.preview(fixture.request())
        #expect(!plan.supported)
        #expect(plan.changes.isEmpty)
        #expect(plan.manualSteps.first?.contains("generator-managed") == true)
        #expect(plan.packageSourceDescription.contains("local package"))
        #expect(plan.manualFiles.count == 4)
        let export = fixture.root.appending(path: "Review")
        let files = try installer.exportManualFiles(plan, to: export)
        #expect(files.count == 4)
        let adapter = try String(contentsOf: export.appending(path: "IntentLabAppAdapter.swift"), encoding: .utf8)
        #expect(adapter.contains("throw IntentLabAppAdapterError.unimplementedObservation"))
        #expect(try Data(contentsOf: export.appending(path: "IntentLabIntegration.json"))
            == Fixture.declarationData)
        #expect(try installer.exportManualFiles(plan, to: export).count == 4)
        let edited = Data("developer edit".utf8)
        let declaration = export.appending(path: "IntentLabIntegration.json")
        try edited.write(to: declaration)
        #expect(throws: IntentLabProjectInstallerError.self) {
            try installer.exportManualFiles(plan, to: export)
        }
        #expect(try Data(contentsOf: declaration) == edited)
    }

    @Test func remotePackageRequiresExactRevisionAndIsReused() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let installer = IntentLabProjectInstaller()
        let remote = URL(string: "https://github.com/example/Intents.git")!
        let unpinned = IntentLabInstallationRequest(
            projectURL: fixture.project, scheme: "FoundationEvals",
            applicationTargetID: fixture.applicationID, uiTestTargetID: fixture.uiTestID,
            packageURL: remote, packageProduct: "IntentLabTesting",
            consumerSource: "import XCTest\n", declarationData: Fixture.declarationData)
        #expect(!(try installer.preview(unpinned)).supported)
        let pinned = IntentLabInstallationRequest(
            projectURL: fixture.project, scheme: "FoundationEvals",
            applicationTargetID: fixture.applicationID, uiTestTargetID: fixture.uiTestID,
            packageURL: remote, packageRevision: String(repeating: "a", count: 40),
            packageProduct: "IntentLabTesting",
            consumerSource: "import XCTest\n", declarationData: Fixture.declarationData)
        let plan = try installer.preview(pinned)
        #expect(plan.supported)
        #expect(plan.packageSourceDescription.contains(String(repeating: "a", count: 40)))
        _ = try installer.apply(plan)
        #expect(try installer.verify(pinned).installed)
        let document = try OpenStepProjectDocument(Data(contentsOf: fixture.project.appending(path: "project.pbxproj")))
        let root = try PropertyListSerialization.propertyList(from: document.data, format: nil) as! [String: Any]
        let objects = root["objects"] as! [String: [String: Any]]
        #expect(objects.values.filter { $0["repositoryURL"] as? String == remote.absoluteString }.count == 1)
    }

    @Test func officialPackageUsesPinnedDefaultAndStillAllowsExplicitRevision() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let official = IntentLabPackageRevisionManifest.packageURL
        let automatic = IntentLabInstallationRequest(
            projectURL: fixture.project, scheme: "FoundationEvals",
            applicationTargetID: fixture.applicationID, uiTestTargetID: fixture.uiTestID,
            packageURL: official, packageProduct: IntentLabPackageRevisionManifest.product,
            consumerSource: "import XCTest\n", declarationData: Fixture.declarationData)
        if let verified = IntentLabPackageRevisionManifest.verifiedRevision {
            #expect(automatic.packageRevision == verified)
            #expect(verified.count == 40)
            #expect(try IntentLabProjectInstaller().preview(automatic).supported)
        } else {
            #expect(automatic.packageRevision == nil)
            let preview = try IntentLabProjectInstaller().preview(automatic)
            #expect(!preview.supported)
            #expect(preview.manualSteps.first?.contains("no verified default package revision") == true)
        }

        let custom = IntentLabInstallationRequest(
            projectURL: fixture.project, scheme: "FoundationEvals",
            applicationTargetID: fixture.applicationID, uiTestTargetID: fixture.uiTestID,
            packageURL: official, packageRevision: String(repeating: "b", count: 40),
            packageProduct: IntentLabPackageRevisionManifest.product,
            consumerSource: "import XCTest\n", declarationData: Fixture.declarationData)
        #expect(custom.packageRevision == String(repeating: "b", count: 40))
    }

    @Test func basicEntryPointCannotAdvertiseAppStateOrSiriSupport() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var declaration = try #require(JSONSerialization.jsonObject(with: Fixture.declarationData) as? [String: Any])
        declaration["capabilities"] = ["environment-payload", "direct-intent-execution", "siri", "accessible-result"]
        let request = IntentLabInstallationRequest(
            projectURL: fixture.project, scheme: "FoundationEvals",
            applicationTargetID: fixture.applicationID, uiTestTargetID: fixture.uiTestID,
            packageURL: fixture.package, packageProduct: "IntentLabTesting",
            consumerSource: "IntentLabBasicIntegration()",
            declarationData: try JSONSerialization.data(withJSONObject: declaration))
        let plan = try IntentLabProjectInstaller().preview(request)
        #expect(!plan.supported)
        #expect(plan.changes.isEmpty)
        #expect(plan.manualSteps.first?.contains("cannot prove app state") == true)
        #expect(plan.manualFiles.contains { $0.filename == "IntentLabAppAdapter.swift" })
    }

    @Test func editedAppAdapterIsNeverReplacedByScaffold() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let installer = IntentLabProjectInstaller()
        let request = fixture.request()
        let initial = try installer.preview(request)
        let adapter = try #require(initial.changes.first { $0.url.lastPathComponent == "IntentLabAppAdapter.swift" }?.url)
        _ = try installer.apply(initial)
        let edit = Data("// Developer-owned app observer implementation\n".utf8)
        try edit.write(to: adapter)
        let second = try installer.preview(request)
        #expect(second.supported)
        #expect(second.changes.allSatisfy { $0.url != adapter })
        #expect(try Data(contentsOf: adapter) == edit)
    }

    @Test func staticInspectionDoesNotRunProjectCode() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let inspection = try IntentLabProjectInstaller.inspect(projectURL: fixture.project)
        #expect(inspection.applications.contains { $0.id == fixture.applicationID })
        #expect(inspection.uiTestTargets.contains { $0.id == fixture.uiTestID })
        #expect(inspection.sharedSchemes.contains("FoundationEvals"))
    }

    @Test func newTargetCanCreateSharedScheme() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let request = IntentLabInstallationRequest(
            projectURL: fixture.project, scheme: "IntentLab",
            applicationTargetID: fixture.applicationID, packageURL: fixture.package,
            packageProduct: "IntentLabTesting", consumerSource: "import XCTest\n",
            declarationData: Fixture.declarationData)
        let installer = IntentLabProjectInstaller()
        let plan = try installer.preview(request)
        #expect(plan.supported)
        _ = try installer.apply(plan)
        let verification = try installer.verify(request)
        #expect(verification.installed, "Missing: \(verification.missing)")
        let scheme = try XMLDocument(data: Data(contentsOf: fixture.project.appending(path: "xcshareddata/xcschemes/IntentLab.xcscheme")))
        #expect(scheme.xmlString.contains("IntentLabUITests.xctest"))
        #expect(scheme.xmlString.contains("Intents.app"))
    }

    @Test func spacesUnicodeAndCustomSchemeSurviveRoundTrip() throws {
        let fixture = try Fixture(pathPrefix: "Intent Lab 測試")
        defer { fixture.cleanup() }
        let schemeURL = fixture.project.appending(path: "xcshareddata/xcschemes/FoundationEvals.xcscheme")
        let scheme = try XMLDocument(data: Data(contentsOf: schemeURL))
        let action = scheme.rootElement()!.elements(forName: "TestAction").first!
        action.addAttribute(XMLNode.attribute(withName: "customOption", stringValue: "preserve-me") as! XMLNode)
        let plans = XMLElement(name: "TestPlans")
        let planReference = XMLElement(name: "TestPlanReference")
        planReference.addAttribute(XMLNode.attribute(withName: "reference", stringValue: "container:Custom.xctestplan") as! XMLNode)
        plans.addChild(planReference)
        action.addChild(plans)
        try scheme.xmlData(options: [.nodePrettyPrint]).write(to: schemeURL)
        let installer = IntentLabProjectInstaller()
        let request = fixture.request()
        let preview = try installer.preview(request)
        #expect(preview.supported)
        _ = try installer.apply(preview)
        #expect(try installer.verify(request).installed)
        let installedScheme = try XMLDocument(data: Data(contentsOf: schemeURL))
        let installedAction = installedScheme.rootElement()!.elements(forName: "TestAction").first!
        #expect(installedAction.attribute(forName: "customOption")?.stringValue == "preserve-me")
        #expect(installedAction.elements(forName: "TestPlans").first?.elements(forName: "TestPlanReference").first?
            .attribute(forName: "reference")?.stringValue == "container:Custom.xctestplan")
    }

    @Test func removalIsExplicitManualReview() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let preview = try IntentLabProjectInstaller().previewRemoval(fixture.request())
        #expect(!preview.automated)
        #expect(preview.filesToReview.count == 5)
        #expect(preview.filesToReview.contains { $0.lastPathComponent == "IntentLabAppAdapter.swift" })
        #expect(preview.steps.contains { $0.contains("preserving edited adapters") })
    }

    @Test func malformedDeclarationDoesNotAppearInstalled() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let request = IntentLabInstallationRequest(
            projectURL: fixture.project, scheme: "FoundationEvals",
            applicationTargetID: fixture.applicationID, uiTestTargetID: fixture.uiTestID,
            packageURL: fixture.package, packageProduct: "IntentLabTesting",
            consumerSource: "import XCTest\n",
            declarationData: Data("{\"capabilities\":[\"direct-intent-execution\"]}".utf8))
        let installer = IntentLabProjectInstaller()
        #expect(!(try installer.preview(request)).supported)
        #expect(!(try installer.verify(request)).installed)
    }

    @Test func installedDeclarationUsesEditedBytesAndSelectedIdentity() throws {
        let generated = try IntentLabProjectInstaller.validateDeclaration(
            Fixture.declarationData, targetBundleIdentifier: "com.example.Consumer", testTargetName: "UITests")
        let editedData = Data(String(decoding: Fixture.declarationData, as: UTF8.self)
            .replacingOccurrences(of: "\"version\":\"1\"", with: "\"version\":\"2\"")
            .utf8)
        let edited = try IntentLabProjectInstaller.validateDeclaration(
            editedData, targetBundleIdentifier: "com.example.Consumer", testTargetName: "UITests")
        #expect(edited.id == generated.id)
        #expect(edited.version == "2")
        #expect(edited.digest == IntentLabProjectInstaller.digest(editedData))
        #expect(edited.digest != generated.digest)
        #expect(throws: IntentLabProjectInstallerError.self) {
            try IntentLabProjectInstaller.validateDeclaration(
                editedData, targetBundleIdentifier: "com.example.Other", testTargetName: "UITests")
        }
        #expect(throws: IntentLabProjectInstallerError.self) {
            try IntentLabProjectInstaller.validateDeclaration(
                editedData, targetBundleIdentifier: "com.example.Consumer", testTargetName: "OtherUITests")
        }
        let noProtocol = Data(String(decoding: editedData, as: UTF8.self)
            .replacingOccurrences(of: "intent-lab-v2", with: "intent-lab-v1").utf8)
        #expect(throws: IntentLabProjectInstallerError.self) {
            try IntentLabProjectInstaller.validateDeclaration(
                noProtocol, targetBundleIdentifier: "com.example.Consumer", testTargetName: "UITests")
        }
    }

    @Test func conventionalUITestTargetCanGainMissingBuildPhases() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let pbxURL = fixture.project.appending(path: "project.pbxproj")
        var document = try OpenStepProjectDocument(Data(contentsOf: pbxURL))
        try document.setKey("buildPhases", value: "()", in: document.object(fixture.uiTestID))
        let syncRange = try document.object(fixture.uiTestID).entries!["fileSystemSynchronizedGroups"]!
        var conventionalData = document.data
        conventionalData.removeSubrange(syncRange)
        _ = try OpenStepProjectDocument(conventionalData)
        try conventionalData.write(to: pbxURL)
        let installer = IntentLabProjectInstaller()
        let request = fixture.request()
        let plan = try installer.preview(request)
        #expect(plan.supported)
        _ = try installer.apply(plan)
        #expect(try installer.verify(request).installed)
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: pbxURL), format: nil) as! [String: Any]
        let objects = plist["objects"] as! [String: [String: Any]]
        let target = objects[fixture.uiTestID]!
        let phaseIDs = target["buildPhases"] as! [String]
        let kinds = Set(phaseIDs.compactMap { objects[$0]?["isa"] as? String })
        #expect(kinds.contains("PBXFrameworksBuildPhase"))
        #expect(kinds.contains("PBXSourcesBuildPhase"))
        #expect(kinds.contains("PBXResourcesBuildPhase"))
    }

    @Test func workspaceSchemeIsEditedAtItsOwningLocation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let workspace = try fixture.makeWorkspace(copyScheme: true)
        let projectScheme = fixture.project.appending(path: "xcshareddata/xcschemes/FoundationEvals.xcscheme")
        try FileManager.default.removeItem(at: projectScheme)
        let inspection = try IntentLabProjectInstaller.inspect(projectURL: fixture.project,
                                                               workspaceURL: workspace)
        #expect(inspection.sharedSchemes == ["FoundationEvals"])
        #expect(inspection.schemeLocations["FoundationEvals"]?.first?.resolvingSymlinksInPath().path
            .hasPrefix(workspace.resolvingSymlinksInPath().path) == true)
        let installer = IntentLabProjectInstaller()
        let request = fixture.request(workspaceURL: workspace)
        let preview = try installer.preview(request)
        #expect(preview.supported)
        #expect(preview.changes.contains { $0.url.path.hasPrefix(workspace.path) })
        _ = try installer.apply(preview)
        #expect(try installer.verify(request).installed)
        #expect(!FileManager.default.fileExists(atPath: projectScheme.path))
        let workspaceScheme = try Data(contentsOf: workspace.appending(path: "xcshareddata/xcschemes/FoundationEvals.xcscheme"))
        let xml = try XMLDocument(data: workspaceScheme)
        let references = try xml.nodes(forXPath: "//BuildableReference").compactMap { $0 as? XMLElement }
        #expect(references.allSatisfy { $0.attribute(forName: "ReferencedContainer")?.stringValue == "container:Consumer.xcodeproj" })
    }

    @Test func duplicateWorkspaceAndProjectSchemesRequireSelection() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let workspace = try fixture.makeWorkspace(copyScheme: true)
        let preview = try IntentLabProjectInstaller().preview(fixture.request(workspaceURL: workspace))
        #expect(!preview.supported)
        #expect(preview.manualSteps.first?.contains("Both the workspace and owning project") == true)
    }

    @Test func workspaceRecoveryRequiresSameApprovedWorkspace() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let workspace = try fixture.makeWorkspace(copyScheme: true)
        try FileManager.default.removeItem(
            at: fixture.project.appending(path: "xcshareddata/xcschemes/FoundationEvals.xcscheme"))
        let installer = IntentLabProjectInstaller()
        let plan = try installer.preview(fixture.request(workspaceURL: workspace))
        let schemeChange = plan.changes.first { $0.url.path.hasPrefix(workspace.path) }!
        let journalURL = fixture.root.appending(path: ".intent-lab-install-journal.json")
        let journal: [String: Any] = [
            "workspacePath": workspace.path,
            "entries": [["path": schemeChange.url.path,
                         "before": schemeChange.previous!.base64EncodedString(),
                         "after": schemeChange.proposed.base64EncodedString()]]
        ]
        try JSONSerialization.data(withJSONObject: journal).write(to: journalURL)
        try schemeChange.proposed.write(to: schemeChange.url)
        #expect(throws: IntentLabProjectInstallerError.self) {
            try installer.recover(projectURL: fixture.project)
        }
        _ = try installer.recover(projectURL: fixture.project, workspaceURL: workspace)
        #expect(try Data(contentsOf: schemeChange.url) == schemeChange.previous)
    }

    @Test func existingScenarioTestClassRequiresMigration() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let legacy = fixture.root.appending(path: "LegacyUITests")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("import XCTest\nfinal class IntentLabScenarioTests: XCTestCase {}".utf8)
            .write(to: legacy.appending(path: "IntentLabScenarioTests.swift"))
        let preview = try IntentLabProjectInstaller().preview(fixture.request())
        #expect(!preview.supported)
        #expect(preview.manualSteps.first?.contains("v1-to-v2 migration") == true)
    }

    @Test func externalCompiledScenarioFileReferenceRequiresMigration() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let pbxURL = fixture.project.appending(path: "project.pbxproj")
        var document = try OpenStepProjectDocument(Data(contentsOf: pbxURL))
        let fileID = "00000000000000000000AB01"
        let buildID = "00000000000000000000AB02"
        try document.addObject(id: fileID, value: "{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ../../Outside/IntentLabScenarioTests.swift; sourceTree = SOURCE_ROOT; }")
        try document.addObject(id: buildID, value: "{isa = PBXBuildFile; fileRef = \(fileID); }")
        let phases = try document.object(fixture.uiTestID).dictionary!["buildPhases"]!.array!.compactMap(\.scalar)
        let sourcePhase = try phases.first { try document.scalar(object: $0, key: "isa") == "PBXSourcesBuildPhase" }!
        try document.append(buildID, toObject: sourcePhase, key: "files")
        try document.data.write(to: pbxURL)
        let preview = try IntentLabProjectInstaller().preview(fixture.request())
        #expect(!preview.supported)
        #expect(preview.manualSteps.first?.contains("already compiles") == true)
    }
}
