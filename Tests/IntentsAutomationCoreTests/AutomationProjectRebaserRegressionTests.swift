import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationProjectRebaserRegressionTests: XCTestCase {
    func testRootValuedSettingsKeepVariableBasedBuildScriptInFrozenSource() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original"), frozen = root.appendingPathComponent("frozen")
        for directory in [original, frozen] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(".build"), withIntermediateDirectories: true)
        }
        let sentinel = original.appendingPathComponent(".build/output")
        try Data("original".utf8).write(to: sentinel)
        let script = "printf generated > \"$MY_BUILD_ROOT/.build/output\""
        let objects: [String: [String: Any]] = [
            "GROUP": ["isa": "PBXGroup", "sourceTree": "<group>", "children": [String]()],
            "CONFIG": ["isa": "XCBuildConfiguration", "buildSettings": ["MY_BUILD_ROOT": original.path, "NESTED": [original.path, original.path + "/Subject.swift"]]],
            "SCRIPT": ["isa": "PBXShellScriptBuildPhase", "shellScript": script]
        ]
        let rebased = try AutomationProjectRebaser.rebase(objects, originalRoot: original, frozenRoot: frozen,
            projectDirectory: original, mainGroupID: "GROUP")
        let settings = try XCTUnwrap(rebased["CONFIG"]?["buildSettings"] as? [String: Any])
        XCTAssertEqual(settings["MY_BUILD_ROOT"] as? String, frozen.path)
        XCTAssertEqual(settings["NESTED"] as? [String], [frozen.path, frozen.path + "/Subject.swift"])
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", try XCTUnwrap(rebased["SCRIPT"]?["shellScript"] as? String)]
        process.environment = ["MY_BUILD_ROOT": try XCTUnwrap(settings["MY_BUILD_ROOT"] as? String)]
        process.currentDirectoryURL = frozen
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: frozen.appendingPathComponent(".build/output"), encoding: .utf8), "generated")
    }
}
