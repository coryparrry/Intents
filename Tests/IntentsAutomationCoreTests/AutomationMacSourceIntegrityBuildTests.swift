#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationMacSourceIntegrityBuildTests: XCTestCase {
    func testBuildMutationCannotProducePreparedCatalogWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["INTENTS_MAC_SOURCE_INTEGRITY_BUILD"] == "1",
              let parentPath = ProcessInfo.processInfo.environment["INTENTS_MAC_SOURCE_INTEGRITY_ROOT"] else {
            throw XCTSkip("Authored private-source mutation build-only check is opt-in")
        }
        let parent = try AutomationPath.canonical(URL(fileURLWithPath: parentPath))
        let root = parent.appendingPathComponent("source-integrity-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let original = root.appendingPathComponent("original"), session = root.appendingPathComponent("prepare")
        let fixture = try AutomationMacInputProbeFixture.write(at: original)
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: fixture.projectData, format: nil) as? [String: Any])
        var objects = try XCTUnwrap(plist["objects"] as? [String: [String: Any]])
        let script = "00000000000000000000000E", marker = "// authored private-source mutation"
        guard objects[script] == nil else { throw AutomationContractError.conflictingOperation }
        let phases = try XCTUnwrap(objects[fixture.targetID]?["buildPhases"] as? [String])
        objects[fixture.targetID]?["buildPhases"] = [script] + phases
        objects[script] = ["isa": "PBXShellScriptBuildPhase", "name": "Authored private-source mutation", "buildActionMask": 2147483647,
            "files": [String](), "inputPaths": [String](), "outputPaths": [String](), "runOnlyForDeploymentPostprocessing": 0,
            "basedOnDependencyAnalysis": 0, "shellPath": "/bin/sh", "shellScript": "printf '\\n" + marker + "\\n' >> \"$SRCROOT/Subject.swift\"\n"]
        plist["objects"] = objects
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: fixture.project.appendingPathComponent("project.pbxproj"))
        let candidate = try XCTUnwrap(AutomationApplicationIntake.assess(fixture.project).candidates.first)
        let templates = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Integration/AutomationHost")
        do {
            _ = try await AutomationPreparation().prepare(candidate: candidate,
                approval: .init(sourceRoot: original.path, candidateID: candidate.id, configuration: "Debug", target: AutomationMacGUIIdentity.currentTarget()),
                sessionRoot: session, templates: templates, developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"))
            XCTFail("Build-mutated captured source must not become a prepared application")
        } catch {
            XCTAssertEqual(error as? AutomationContractError, .conflictingOperation)
        }
        let manifest = try JSONDecoder().decode(AutomationSourceManifest.self, from: Data(contentsOf: session.appendingPathComponent("source-manifest.json")))
        try AutomationSourceSnapshot.verifyOriginal(manifest)
        XCTAssertFalse(try String(contentsOf: original.appendingPathComponent("Subject.swift"), encoding: .utf8).contains(marker))
        XCTAssertTrue(try String(contentsOf: session.appendingPathComponent("source/Subject.swift"), encoding: .utf8).contains(marker))
        let log = try String(contentsOf: session.appendingPathComponent("build.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("** TEST BUILD SUCCEEDED **"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.appendingPathComponent("prepared-application.json").path))
        print("Owned private-source mutation fixture: \(root.path); successful app/host build rejected before catalog persistence; original source preserved; no runtime launched")
    }
}
#endif
