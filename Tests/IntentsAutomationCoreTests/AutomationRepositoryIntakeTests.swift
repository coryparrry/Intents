import XCTest
@testable import IntentsAutomationCore

final class AutomationRepositoryIntakeTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("intents-intake-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult private func project(_ path: String, name: String = "Subject") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let objects: [String: Any] = [
            "APP": ["isa": "PBXNativeTarget", "name": name, "productType": "com.apple.product-type.application", "buildConfigurationList": "CONFIG"],
            "CONFIG": ["buildConfigurations": ["DEV"]], "DEV": ["name": "Development"]
        ]
        try PropertyListSerialization.data(fromPropertyList: ["objects": objects], format: .xml, options: 0).write(to: url.appendingPathComponent("project.pbxproj"))
        return url
    }
    @discardableResult private func workspace(_ path: String, references: [String]) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let xml = "<Workspace>" + references.map { "<FileRef location=\"group:" + $0 + "\"/>" }.joined() + "</Workspace>"
        try Data(xml.utf8).write(to: url.appendingPathComponent("contents.xcworkspacedata"))
        return url
    }
    func testNestedApplicationsRetainActualProjectAndConfiguration() throws {
        let app = try project("Applications/iPhone/Subject.xcodeproj")
        let result = try AutomationApplicationIntake.assess(root)
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates[0].containerPath, app.path)
        XCTAssertEqual(result.candidates[0].id, app.path + "#APP")
        XCTAssertEqual(result.candidates[0].configurations, ["Development"])
        XCTAssertTrue(result.requiresBuildApproval)
    }
    func testWorkspaceAndProjectReferencesDoNotDuplicateTargets() throws {
        try project("Apps/Subject.xcodeproj")
        try workspace("Subject.xcworkspace", references: ["Apps/Subject.xcodeproj", "Apps/Subject.xcodeproj"])
        try workspace("Build/Subject.xcworkspace", references: ["../Apps/Subject.xcodeproj"])
        let candidates = try AutomationApplicationIntake.assess(root).candidates
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.workspacePath, root.appendingPathComponent("Subject.xcworkspace").path)
    }
    func testMultiplePrimaryWorkspacesRemainDistinctBuildChoices() throws {
        try project("Apps/Subject.xcodeproj")
        try workspace("First.xcworkspace", references: ["Apps/Subject.xcodeproj"])
        try workspace("Second.xcworkspace", references: ["Apps/Subject.xcodeproj"])
        let candidates = try AutomationApplicationIntake.assess(root).candidates
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(Set(candidates.map(\.id)).count, 2)
        XCTAssertEqual(Set(candidates.compactMap(\.workspacePath)).count, 2)
    }
    func testNestedWorkspaceCanResolveSiblingOnlyWithinSelectedRoot() throws {
        let app = try project("Apps/Subject.xcodeproj")
        let container = try workspace("Containers/Subject.xcworkspace", references: ["../Apps/Subject.xcodeproj"])
        XCTAssertTrue(try AutomationWorkspaceProjects.resolve(container).projects.isEmpty)
        XCTAssertEqual(try AutomationWorkspaceProjects.resolve(container, authorizedRoot: root).projects.map(\.path), [app.path])
    }
    func testDependenciesExamplesCachesAndProductContentsAreExcluded() throws {
        try project("Apps/Real.xcodeproj", name: "Real")
        for directory in ["vendor", "node_modules", "Pods", "Examples", ".build", "DerivedData", "Demo.app", "Old.xcarchive", "Fixtures"] {
            try project(directory + "/Hidden.xcodeproj", name: "Hidden")
        }
        try workspace("Subject.xcworkspace", references: ["Examples/Hidden.xcodeproj"])
        XCTAssertEqual(try AutomationApplicationIntake.assess(root).candidates.map(\.name), ["Real"])
        XCTAssertEqual(try AutomationApplicationIntake.assess(root.appendingPathComponent("Examples")).candidates.map(\.name), ["Hidden"])
    }
    func testMalformedProjectAndWorkspaceDoNotHideAnotherApplication() throws {
        try project("Good/Subject.xcodeproj")
        let bad = try project("Bad.xcodeproj")
        try Data("not a project".utf8).write(to: bad.appendingPathComponent("project.pbxproj"))
        let broken = try workspace("Broken.xcworkspace", references: [])
        try Data("<Workspace>".utf8).write(to: broken.appendingPathComponent("contents.xcworkspacedata"))
        let result = try AutomationApplicationIntake.assess(root)
        XCTAssertEqual(result.candidates.map(\.name), ["Subject"])
        XCTAssertTrue(result.gaps.contains { $0.contains("Bad.xcodeproj") })
        XCTAssertTrue(result.gaps.contains { $0.contains("Broken.xcworkspace") })
    }
    func testSameNamedAppsRemainDistinctAndDeterministicallyOrdered() throws {
        let second = try project("B/Subject.xcodeproj"), first = try project("A/Subject.xcodeproj")
        XCTAssertEqual(try AutomationApplicationIntake.assess(root).candidates.map(\.containerPath), [first.path, second.path])
    }
    func testSymbolicLinksAreNotTraversedOrAcceptedThroughWorkspace() throws {
        let external = root.appendingPathComponent("Outside")
        let source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try project("Outside/Escape.xcodeproj")
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("Linked"), withDestinationURL: external)
        try workspace("Source/Subject.xcworkspace", references: ["Linked/Escape.xcodeproj", "../Outside/Escape.xcodeproj"])
        let result = try AutomationApplicationIntake.assess(source)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertTrue(result.gaps.contains { $0.contains("outside the authorised") })
    }
    func testWorkspaceRetainsSafeInRootSymbolicProjectReference() throws {
        let app = try project("Apps/Subject.xcodeproj")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Linked.xcodeproj"), withDestinationURL: app)
        let container = try workspace("Subject.xcworkspace", references: ["Linked.xcodeproj"])
        XCTAssertEqual(try AutomationWorkspaceProjects.resolve(container).projects.map(\.path), [app.path])
        XCTAssertEqual(try AutomationApplicationIntake.assess(root).candidates.count, 1)
    }
    func testBoundedDiscoveryReportsPartialResults() throws {
        try project("A/B/C/Subject.xcodeproj")
        let limited = try AutomationSourceEntryPoints.discover(root, limits: .init(depth: 1, directories: 100, entries: 100))
        XCTAssertTrue(limited.projects.isEmpty)
        XCTAssertTrue(limited.gaps.contains { $0.contains("inspection limit") })
        let entryLimit = try AutomationSourceEntryPoints.discover(root, limits: .init(depth: 10, directories: 100, entries: 1))
        XCTAssertFalse(entryLimit.gaps.isEmpty)
    }
    func testEntryPointLimitBoundsProjectParsing() throws {
        try project("A.xcodeproj"); try project("B.xcodeproj")
        let limited = try AutomationSourceEntryPoints.discover(root, limits: .init(entryPoints: 1))
        XCTAssertEqual(limited.projects.count, 1)
        XCTAssertTrue(limited.gaps.contains { $0.contains("inspection limit") })
    }
    func testActualRepositoryFolderFindsAppWithoutProjectChangesWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["INTENTS_INTAKE_REPOSITORY"] else { throw XCTSkip("No explicit repository intake profile") }
        let repository = try AutomationPath.canonical(URL(fileURLWithPath: path))
        let project = repository.appendingPathComponent("FoundationEvals/FoundationEvals.xcodeproj/project.pbxproj")
        let before = try Data(contentsOf: project)
        let result = try AutomationApplicationIntake.assess(repository)
        XCTAssertTrue(result.candidates.contains { $0.containerPath == project.deletingLastPathComponent().path && $0.name == "FoundationEvals" })
        XCTAssertEqual(try Data(contentsOf: project), before)
    }
    func testNoApplicationIsAssessmentNotFalseSuccess() throws {
        let result = try AutomationApplicationIntake.assess(root)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertTrue(result.gaps.contains { $0.contains("No application target") })
    }
    func testNonDirectoryInputIsRejected() throws {
        let file = root.appendingPathComponent("README.md")
        try Data("text".utf8).write(to: file)
        XCTAssertThrowsError(try AutomationApplicationIntake.assess(file))
    }

    private func archivedApp(_ name: String = "Subject", mac: Bool = true) throws -> URL {
        let app = root.appendingPathComponent("Build.xcarchive/Products/Applications/" + name + ".app")
        let infoDirectory = mac ? app.appendingPathComponent("Contents") : app
        let binary = mac ? infoDirectory.appendingPathComponent("MacOS/Subject") : app.appendingPathComponent("Subject")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleName": name, "CFBundleIdentifier": "example." + name,
                                   "CFBundleExecutable": "Subject", "CFBundleSupportedPlatforms": [mac ? "MacOSX" : "iPhoneOS"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoDirectory.appendingPathComponent("Info.plist"))
        try Data([0xcf,0xfa,0xed,0xfe,0x0c,0,0,1,0,0,0,0]).write(to: binary)
        return app
    }
    func testArchiveInspectsActualMacProductWithoutExportOrResigning() throws {
        let app = try archivedApp()
        let before = try AutomationProductDigest.compute(bundle: app, version: 2)
        let result = try AutomationApplicationIntake.assess(root.appendingPathComponent("Build.xcarchive"))
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates[0].containerPath, app.path)
        XCTAssertEqual(result.candidates[0].app?.productDigest, before)
        XCTAssertEqual(result.candidates[0].platform, "macos")
        XCTAssertFalse(result.requiresBuildApproval)
        XCTAssertEqual(try AutomationProductDigest.compute(bundle: app, version: 2), before)
    }
    func testArchiveRetainsActualDevicePlatformAndMultipleProducts() throws {
        try archivedApp("Phone", mac: false)
        try archivedApp("Mac")
        let result = try AutomationApplicationIntake.assess(root.appendingPathComponent("Build.xcarchive"))
        XCTAssertEqual(result.candidates.map(\.name), ["Mac", "Phone"])
        XCTAssertEqual(result.candidates.map(\.platform), ["macos", "ios"])
    }
    func testInvalidAndLinkedArchiveProductsCannotHideValidProductOrEscape() throws {
        let good = try archivedApp("Good")
        let bad = try archivedApp("Bad")
        try Data("invalid".utf8).write(to: bad.appendingPathComponent("Contents/MacOS/Subject"))
        try FileManager.default.createSymbolicLink(at: good.deletingLastPathComponent().appendingPathComponent("Linked.app"), withDestinationURL: good)
        let result = try AutomationApplicationIntake.assess(root.appendingPathComponent("Build.xcarchive"))
        XCTAssertEqual(result.candidates.map(\.name), ["Good"])
        XCTAssertEqual(result.gaps.filter { $0.contains("Could not validate") }.count, 2)
    }
    func testArchiveProductsDirectoryCannotBeSymbolicLink() throws {
        try project("Outside/Placeholder.xcodeproj")
        let products = root.appendingPathComponent("Build.xcarchive/Products")
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: products.appendingPathComponent("Applications"), withDestinationURL: root.appendingPathComponent("Outside"))
        XCTAssertThrowsError(try AutomationApplicationIntake.assess(root.appendingPathComponent("Build.xcarchive")))
    }
}
