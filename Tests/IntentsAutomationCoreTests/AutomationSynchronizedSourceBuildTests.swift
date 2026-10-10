#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationSynchronizedSourceBuildTests: XCTestCase {
    func testActualSynchronizedSwiftMembershipBuildsAndReloadsWithoutRuntimeWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["INTENTS_SYNC_SOURCE_BUILD"] == "1",
              let path = ProcessInfo.processInfo.environment["INTENTS_SYNC_SOURCE_ROOT"] else {
            throw XCTSkip("Authored synchronized-folder SDK build-only check is opt-in")
        }
        let parent = try AutomationPath.canonical(URL(fileURLWithPath: path))
        let root = parent.appendingPathComponent("fixture-" + UUID().uuidString), source = root.appendingPathComponent("App")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let fixture = try AutomationMacInputProbeFixture.write(at: source)
        let directory = source.appendingPathComponent("Synced")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: source.appendingPathComponent("Subject.swift"), to: directory.appendingPathComponent("Subject.swift"))
        var project = try PropertyListSerialization.propertyList(from: fixture.projectData, format: nil) as! [String: Any]
        var objects = project["objects"] as! [String: [String: Any]]
        let projectID = project["rootObject"] as! String, main = objects[projectID]!["mainGroup"] as! String
        // Moving the file into synchronized membership also removes its old explicit reference.
        let oldReferences = Set(objects.keys.filter { objects[$0]?["isa"] as? String == "PBXFileReference" && objects[$0]?["path"] as? String == "Subject.swift" })
        for id in Array(objects.keys) {
            if oldReferences.contains(id) || (objects[id]?["fileRef"] as? String).map(oldReferences.contains) == true {
                objects.removeValue(forKey: id)
            } else if let children = objects[id]?["children"] as? [String] {
                objects[id]?["children"] = children.filter { !oldReferences.contains($0) }
            }
        }
        let sync = "DDDDDDDDDDDDDDDDDDDDDDD1"
        objects[sync] = ["isa": "PBXFileSystemSynchronizedRootGroup", "path": "Synced", "sourceTree": "<group>",
                         "exceptions": [String](), "explicitFolders": [String](), "explicitFileTypes": [String: String]()]
        objects[main]!["children"] = (objects[main]!["children"] as! [String]) + [sync]
        objects[fixture.targetID]!["fileSystemSynchronizedGroups"] = [sync]
        for id in objects.keys where objects[id]?["isa"] as? String == "PBXSourcesBuildPhase" { objects[id]!["files"] = [String]() }
        project["objects"] = objects
        try PropertyListSerialization.data(fromPropertyList: project, format: .xml, options: 0).write(to: fixture.project.appendingPathComponent("project.pbxproj"))
        let candidate = try XCTUnwrap(AutomationApplicationIntake.assess(fixture.project).candidates.first)
        let templates = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Integration/AutomationHost")
        let target = try AutomationMacGUIIdentity.currentTarget()
        let prepared = try await AutomationPreparation().prepare(candidate: candidate,
            approval: .init(sourceRoot: source.path, candidateID: candidate.id, configuration: "Debug", target: target),
            sessionRoot: root.appendingPathComponent("prepare-" + UUID().uuidString), templates: templates,
            developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"))
        let graph = try XCTUnwrap(prepared.sourceGraph), syntax = try XCTUnwrap(prepared.sourceSyntax)
        XCTAssertEqual(graph.synchronizedMembershipVersion, 1)
        XCTAssertTrue(graph.inputs.contains { $0.relativePath == "Synced/Subject.swift" && $0.role == "synchronizedSwiftMembership" })
        XCTAssertTrue(syntax.inputs.contains { $0.relativePath == "Synced/Subject.swift" && $0.role == "synchronizedSwiftMembership" })
        XCTAssertTrue(prepared.catalog.systemActions.contains { $0.id == "HostProbeIntent" && $0.compiled && !$0.executed && !$0.registered })
        XCTAssertEqual(try AutomationPreparedApplicationRecord.load(app: prepared.host.app, supportRoot: root), prepared)
        let privateRoot = URL(fileURLWithPath: prepared.generatedHost.projectPath).deletingLastPathComponent()
        let copied = privateRoot.appendingPathComponent("Synced/Subject.swift")
        let original = try Data(contentsOf: copied)
        try Data("struct Changed {}".utf8).write(to: copied)
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: prepared.host.app, supportRoot: root))
        try original.write(to: copied)
        try AutomationSourceSnapshot.verifyOriginal(prepared.source)
        print("Owned synchronized source build: \(root.path); subjectSHA256 \(prepared.host.app.productDigest ?? "unknown"); hostSHA256 \(prepared.host.hostProductDigest)")
        print("Captured synchronized Swift membership reconciles with compiled metadata and saved reload; no app or intent runtime launched")
    }
}
#endif
