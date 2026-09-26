import Foundation
import Testing
@testable import FoundationEvals

struct IntentLabProjectInstallerTests {
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

        func request(existingTarget: Bool = true, workspaceURL: URL? = nil) -> IntentLabInstallationRequest {
            .init(projectURL: project, workspaceURL: workspaceURL,
                  scheme: "FoundationEvals", applicationTargetID: applicationID,
                  uiTestTargetID: existingTarget ? uiTestID : nil, packageURL: package,
                  packageProduct: "IntentLabTesting",
                  consumerSource: "import XCTest\nfinal class IntentLabScenarioTests: XCTestCase {}\n",
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

    @Test func existingTargetRoundTripAndIdempotence() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let installer = IntentLabProjectInstaller()
        let request = fixture.request()
        let original = try Data(contentsOf: fixture.project.appending(path: "project.pbxproj"))
        let preview = try installer.preview(request)
        #expect(preview.supported)
        #expect(preview.changes.count == 4)
        #expect(preview.changes.allSatisfy { $0.afterDigest != $0.beforeDigest })
        let receipt = try installer.apply(preview)
        #expect(receipt.changedFiles.count == 4)
        let verification = try installer.verify(request)
        #expect(verification.installed, "Missing: \(verification.missing)")
        #expect(try installer.preview(request).changes.isEmpty)
        #expect(try installer.repair(request).alreadyInstalled)
        let installed = try Data(contentsOf: fixture.project.appending(path: "project.pbxproj"))
        #expect(installed.starts(with: Data(original.prefix(80))))
        let plist = try PropertyListSerialization.propertyList(from: installed, format: nil) as! [String: Any]
        let objects = plist["objects"] as! [String: [String: Any]]
        let target = objects[fixture.uiTestID]!
        let listID = target["buildConfigurationList"] as! String
        let configIDs = objects[listID]!["buildConfigurations"] as! [String]
        for configID in configIDs {
            let settings = objects[configID]!["buildSettings"] as! [String: Any]
            #expect(settings["INTENT_LAB_HARNESS_VERSION"] as? String == "intent-lab-v2")
            #expect((settings["INTENT_LAB_HARNESS_CAPABILITIES"] as? String)?.contains("direct-intent-execution") == true)
        }
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
        #expect(plan.manualFiles.count == 3)
        let export = fixture.root.appending(path: "Review")
        let files = try installer.exportManualFiles(plan, to: export)
        #expect(files.count == 3)
        #expect(try Data(contentsOf: export.appending(path: "IntentLabIntegration.json"))
            == Fixture.declarationData)
        #expect(try installer.exportManualFiles(plan, to: export).count == 3)
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
        #expect(preview.filesToReview.count == 4)
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
