#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

final class AutomationMultiRootPreparationTests: XCTestCase, @unchecked Sendable {
    private func root() throws -> URL {
        let value = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("multi-root-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }; return value
    }
    func testSchema2GraphAndIsolationPreserveGrantedSiblingGroupsAndTransitivePackages() throws {
        let root = try root(), fixture = try AutomationMultiRootPackageFixture.write(root)
        let session = root.appendingPathComponent("session")
        let manifest = try AutomationSourceSnapshot.capture(source: fixture.app, sessionRoot: session, additionalRoots: [fixture.shared, fixture.leaf])
        let graph = try AutomationSourceGraphReader.read(manifest: manifest, frozenRoot: session.appendingPathComponent("source"),
            projectRelativePath: "App/Subject.xcodeproj", targetID: fixture.targetID, configuration: "Debug")
        for path in ["Packages/Shared/Package.swift", "Packages/Leaf/Package.swift", "Packages/Shared/Sources/Shared/Shared.swift", "Packages/Leaf/Sources/Leaf/Leaf.swift", "Packages/Shared/Extras/Extra.swift"] {
            XCTAssertTrue(graph.inputs.contains { $0.relativePath == path }, path)
        }
        XCTAssertFalse(graph.gaps.contains { $0.contains("External source root") || $0.contains("External package root") || $0.contains("outside the captured source") })
        try AutomationPreparedSourceIntegrity.verify(graph: graph, manifest: manifest, frozenRoot: session.appendingPathComponent("source"))
        let isolated = try AutomationHostGenerator.isolateProject(sessionRoot: session, projectRelativePath: "App/Subject.xcodeproj")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: isolated.project.appendingPathComponent("project.pbxproj")), format: nil) as? [String: Any])
        let objects = try XCTUnwrap(plist["objects"] as? [String: [String: Any]])
        XCTAssertEqual(objects["EEEEEEEEEEEEEEEEEEEEEEE1"]?["relativePath"] as? String, "../Packages/Shared")
        XCTAssertEqual(objects["EEEEEEEEEEEEEEEEEEEEEEE4"]?["path"] as? String, "..")
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.appendingPathComponent("source/Packages/Leaf/Package.swift").path))
        try AutomationSourceSnapshot.verifyOriginal(manifest)
    }
    func testUngrantedSiblingAndScaffoldLeafNeverBecomePrivateInputs() throws {
        let root = try root(), fixture = try AutomationMultiRootPackageFixture.write(root)
        let session = root.appendingPathComponent("narrow")
        let manifest = try AutomationSourceSnapshot.capture(source: fixture.app, sessionRoot: session)
        let graph = try AutomationSourceGraphReader.read(manifest: manifest, frozenRoot: session.appendingPathComponent("source"),
            projectRelativePath: "Subject.xcodeproj", targetID: fixture.targetID, configuration: "Debug")
        XCTAssertTrue(graph.gaps.contains { $0.contains("External source root") || $0.contains("External package root") })
        XCTAssertFalse(graph.inputs.contains { $0.relativePath.contains("Shared") || $0.relativePath.contains("Leaf") })
        XCTAssertThrowsError(try AutomationHostGenerator.isolateProject(sessionRoot: session, projectRelativePath: "Subject.xcodeproj"))
        let partial = root.appendingPathComponent("partial")
        let limited = try AutomationSourceSnapshot.capture(source: fixture.app, sessionRoot: partial, additionalRoots: [fixture.shared])
        let missing = try AutomationSourceGraphReader.read(manifest: limited, frozenRoot: partial.appendingPathComponent("source"),
            projectRelativePath: "App/Subject.xcodeproj", targetID: fixture.targetID, configuration: "Debug")
        XCTAssertTrue(missing.gaps.contains { $0.contains("outside the captured source") })
        XCTAssertFalse(missing.inputs.contains { $0.relativePath.hasPrefix("Packages/Leaf/") })
    }
    func testReturnedRootGrantsMustMatchExactBuildApproval() throws {
        let root = try root(), fixture = try AutomationMultiRootPackageFixture.write(root)
        let manifest = try AutomationSourceSnapshot.capture(source: fixture.app, sessionRoot: root.appendingPathComponent("session"), additionalRoots: [fixture.shared, fixture.leaf])
        let target = TargetIdentity(id: "fixture", kind: .simulator)
        let approval = AutomationBuildApproval(sourceRoot: fixture.app.path, candidateID: "fixture", configuration: "Debug", target: target,
            additionalSourceRoots: [fixture.shared.path, fixture.leaf.path])
        try approval.validateSourceManifest(manifest)
        for extras in [[], [fixture.shared.path], [fixture.shared.path, fixture.shared.path], [fixture.shared.path, root.appendingPathComponent("Other").path]] {
            XCTAssertThrowsError(try AutomationBuildApproval(sourceRoot: fixture.app.path, candidateID: "fixture", configuration: "Debug", target: target, additionalSourceRoots: extras).validateSourceManifest(manifest))
        }
        XCTAssertThrowsError(try AutomationBuildApproval(sourceRoot: root.path, candidateID: "fixture", configuration: "Debug", target: target,
            additionalSourceRoots: [fixture.shared.path, fixture.leaf.path]).validateSourceManifest(manifest))
    }
    func testActualGrantedLocalPackageClosureBuildsAndReloadsWithoutRuntimeWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["INTENTS_MULTI_ROOT_BUILD"] == "1", let path = ProcessInfo.processInfo.environment["INTENTS_MULTI_ROOT_ROOT"] else {
            throw XCTSkip("Authored explicit additional-root SDK build-only check is opt-in")
        }
        let parent = try AutomationPath.canonical(URL(fileURLWithPath: path)), root = parent.appendingPathComponent("fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let fixture = try AutomationMultiRootPackageFixture.write(root)
        let candidate = try XCTUnwrap(AutomationApplicationIntake.assess(fixture.project).candidates.first)
        let templates = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Integration/AutomationHost")
        let approval = AutomationBuildApproval(sourceRoot: fixture.app.path, candidateID: candidate.id, configuration: "Debug", target: try AutomationMacGUIIdentity.currentTarget(), additionalSourceRoots: [fixture.shared.path, fixture.leaf.path])
        let prepared = try await AutomationPreparation().prepare(candidate: candidate, approval: approval,
            sessionRoot: root.appendingPathComponent("prepare-" + UUID().uuidString), templates: templates, developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"))
        XCTAssertEqual(prepared.source.schemaVersion, 2); try approval.validateSourceManifest(prepared.source)
        XCTAssertTrue(prepared.sourceGraph?.inputs.contains { $0.relativePath == "Packages/Leaf/Sources/Leaf/Leaf.swift" } == true)
        XCTAssertTrue(prepared.catalog.systemActions.contains { $0.id == "HostProbeIntent" && $0.compiled && !$0.executed && !$0.registered })
        try AutomationSourceSnapshot.verifyOriginal(prepared.source)
        XCTAssertEqual(try AutomationPreparedApplicationRecord.load(app: prepared.host.app, supportRoot: root), prepared)
        print("Owned additional-root package build: \(root.path); subjectSHA256 \(prepared.host.app.productDigest ?? "unknown"); hostSHA256 \(prepared.host.hostProductDigest)")
        print("Explicit copied sibling source and transitive local packages compiled/reloaded; no app/intent runtime launched; compiler source provenance remains partial")
    }
}
#endif
