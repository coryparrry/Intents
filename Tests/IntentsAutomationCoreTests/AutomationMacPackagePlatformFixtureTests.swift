#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationMacPackagePlatformFixtureTests: XCTestCase {
    private func write(at root: URL) throws -> AutomationMacInputProbeFixture.Fixture {
        let base = try AutomationMacInputProbeFixture.write(at: root)
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: base.projectData, format: nil) as? [String: Any])
        var objects = try XCTUnwrap(plist["objects"] as? [String: [String: Any]])
        let projectID = try XCTUnwrap(plist["rootObject"] as? String)
        let phases = try XCTUnwrap(objects[base.targetID]?["buildPhases"] as? [String])
        let frameworks = try XCTUnwrap(phases.first { objects[$0]?["isa"] as? String == "PBXFrameworksBuildPhase" })
        let (reference, product, build) = ("00000000000000000000000E", "00000000000000000000000F", "000000000000000000000010")
        guard [reference, product, build].allSatisfy({ objects[$0] == nil }) else { throw AutomationContractError.conflictingOperation }
        objects[projectID]?["packageReferences"] = [reference]
        objects[reference] = ["isa": "XCLocalSwiftPackageReference", "relativePath": "PlatformPackage"]
        objects[product] = ["isa": "XCSwiftPackageProductDependency", "productName": "PlatformFixture", "package": reference]
        objects[build] = ["isa": "PBXBuildFile", "productRef": product]
        objects[frameworks]?["files"] = [build]
        objects[base.targetID]?["packageProductDependencies"] = [product]
        plist["objects"] = objects
        let projectData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try projectData.write(to: base.project.appendingPathComponent("project.pbxproj"))
        let source = AutomationMacInputProbeFixture.source.replacingOccurrences(of: "import AppIntents", with: "import AppIntents\nimport PlatformMain")
            .replacingOccurrences(of: "Text(\"Intents input adapter fixture\")", with: "Text(platformMarker())")
        try Data(source.utf8).write(to: root.appendingPathComponent("Subject.swift"))
        let files = [
            "PlatformPackage/Package.swift": """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(name: "PlatformFixture", platforms: [.macOS(.v14), .iOS(.v17)],
                products: [.library(name: "PlatformFixture", targets: ["PlatformMain"])], targets: [
                    .target(name: "PlatformMain", dependencies: [.target(name: "MacMarker", condition: .when(platforms: [.macOS])), .target(name: "IOSMarker", condition: .when(platforms: [.iOS]))]),
                    .target(name: "MacMarker"), .target(name: "IOSMarker")])
            """,
            "PlatformPackage/Sources/PlatformMain/Member.swift": """
            #if os(macOS)
            import MacMarker
            #elseif os(iOS)
            import IOSMarker
            #endif
            public func platformMarker() -> String { marker }
            """,
            "PlatformPackage/Sources/MacMarker/Mac.swift": "public let marker = \"Mac fixture\"\n",
            "PlatformPackage/Sources/IOSMarker/IOS.swift": "public let marker = \"iOS fixture\"\n"
        ]
        for (path, text) in files {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(text.utf8).write(to: file, options: .withoutOverwriting)
        }
        return .init(project: base.project, targetID: base.targetID, projectData: projectData)
    }
    func testActualLiteralPlatformPackageBuildWithoutLaunchingWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["INTENTS_MAC_PACKAGE_PLATFORM_BUILD"] == "1",
              let parentPath = ProcessInfo.processInfo.environment["INTENTS_MAC_PACKAGE_PLATFORM_ROOT"] else {
            throw XCTSkip("Authored local-package platform build-only check is opt-in")
        }
        let parent = try AutomationPath.canonical(URL(fileURLWithPath: parentPath))
        let root = parent.appendingPathComponent("package-platform-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let fixture = try write(at: root.appendingPathComponent("original"))
        let candidate = try XCTUnwrap(AutomationApplicationIntake.assess(fixture.project).candidates.first)
        let templates = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Integration/AutomationHost")
        let prepared = try await AutomationPreparation().prepare(candidate: candidate,
            approval: .init(sourceRoot: root.appendingPathComponent("original").path, candidateID: candidate.id, configuration: "Debug", target: AutomationMacGUIIdentity.currentTarget()),
            sessionRoot: root.appendingPathComponent("prepare"), templates: templates, developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"))
        try AutomationSourceSnapshot.verifyOriginal(prepared.source)
        let graph = try XCTUnwrap(prepared.sourceGraph)
        XCTAssertEqual(graph.packagePlatformConditionVersion, 1); XCTAssertEqual(graph.platformContext?.filterFamily, "macos")
        XCTAssertEqual(graph.inputs.filter { $0.role == "packageSwiftMembership" }.map(\.relativePath).sorted(), ["PlatformPackage/Sources/MacMarker/Mac.swift", "PlatformPackage/Sources/PlatformMain/Member.swift"])
        XCTAssertFalse(graph.inputs.contains { $0.relativePath.contains("IOSMarker") })
        XCTAssertEqual(graph.coverage, "partial")
        XCTAssertEqual(try AutomationMacInputProbeFixture.validateCatalog(prepared.catalog, app: prepared.host.app), "HostProbeIntent")
        print("Owned package-platform build evidence: \(root.path); subjectSHA256 \(prepared.host.app.productDigest ?? "unknown"); hostSHA256 \(prepared.host.hostProductDigest)")
        print("Authored native Mac conditional package and associated host built; no app, probe or intent runtime launched")
    }
}
#endif
