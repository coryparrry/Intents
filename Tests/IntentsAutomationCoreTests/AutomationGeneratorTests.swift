import XCTest
@testable import IntentsAutomationCore

final class AutomationGeneratorTests: XCTestCase {
    func testAbsoluteLiveSourceIsRebasedAndExternalRelativeReferencesAreRejected() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let original = root.appendingPathComponent("original"), frozen = root.appendingPathComponent("frozen")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("input".utf8).write(to: original.appendingPathComponent("App.swift"))
        try Data("external".utf8).write(to: root.appendingPathComponent("Outside.swift"))
        var objects: [String: [String: Any]] = ["MAIN": ["isa": "PBXGroup", "children": ["FILE"]],
            "FILE": ["isa": "PBXFileReference", "sourceTree": "<absolute>", "path": original.appendingPathComponent("App.swift").path]]
        let rebased = try AutomationProjectRebaser.rebase(objects, originalRoot: original, frozenRoot: frozen, projectDirectory: original, mainGroupID: "MAIN")
        XCTAssertEqual(rebased["FILE"]?["path"] as? String, frozen.appendingPathComponent("App.swift").path)
        objects["FILE"] = ["isa": "PBXFileReference", "sourceTree": "<group>", "path": "../Outside.swift"]
        XCTAssertThrowsError(try AutomationProjectRebaser.rebase(objects, originalRoot: original, frozenRoot: frozen, projectDirectory: original, mainGroupID: "MAIN"))
        objects["FILE"] = ["isa": "PBXFileReference", "sourceTree": "<group>", "path": "App.swift"]
        for tree in ["SDKROOT", "DEVELOPER_DIR", "BUILT_PRODUCTS_DIR"] {
            objects["FILE"] = ["isa": "PBXFileReference", "sourceTree": tree, "path": "../../original/App.swift"]
            XCTAssertThrowsError(try AutomationProjectRebaser.rebase(objects, originalRoot: original, frozenRoot: frozen, projectDirectory: original, mainGroupID: "MAIN"))
            for path in [nil, ""] as [String?] {
                objects["MAIN"] = ["isa": "PBXGroup", "sourceTree": tree, "children": ["FILE"]]
                if let path { objects["MAIN"]?["path"] = path }
                XCTAssertThrowsError(try AutomationProjectRebaser.rebase(objects, originalRoot: original, frozenRoot: frozen, projectDirectory: original, mainGroupID: "MAIN"))
            }
            objects["MAIN"] = ["isa": "PBXGroup", "children": ["FILE"]]
        }
        objects["FILE"] = ["isa": "PBXFileReference", "sourceTree": "<group>", "path": "App.swift"]
        let example = original.appendingPathComponent("Example")
        try FileManager.default.createDirectory(at: example, withIntermediateDirectories: true)
        objects["FILE"] = ["isa": "PBXFileReference", "sourceTree": "<absolute>", "path": original.appendingPathComponent("App.swift").path]
        objects["PACKAGE"] = ["isa": "XCLocalSwiftPackageReference", "relativePath": ".."]
        XCTAssertNoThrow(try AutomationProjectRebaser.rebase(objects, originalRoot: original, frozenRoot: frozen, projectDirectory: example, mainGroupID: "MAIN"))
        objects.removeValue(forKey: "PACKAGE")
        objects["SCRIPT"] = ["isa": "PBXShellScriptBuildPhase", "shellScript": "cat \(original.path)/App.swift"]
        XCTAssertThrowsError(try AutomationProjectRebaser.rebase(objects, originalRoot: original, frozenRoot: frozen, projectDirectory: original, mainGroupID: "MAIN"))
    }
    func testAssociatedHostIsGeneratedOnlyInSnapshotWithActualConfiguration() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let original = root.appendingPathComponent("original"), project = original.appendingPathComponent("Subject.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let objects: [String: Any] = [
            "ROOT": ["isa": "PBXProject", "mainGroup": "MAIN", "productRefGroup": "PRODUCTS", "targets": ["APP"], "buildConfigurationList": "PROJECT_CONFIGS"],
            "MAIN": ["isa": "PBXGroup", "children": ["PRODUCTS"]], "PRODUCTS": ["isa": "PBXGroup", "children": [String]()],
            "APP": ["isa": "PBXNativeTarget", "name": "Subject", "productType": "com.apple.product-type.application", "buildConfigurationList": "APP_CONFIGS"],
            "APP_CONFIGS": ["isa": "XCConfigurationList", "buildConfigurations": ["APP_CONFIG"]],
            "APP_CONFIG": ["isa": "XCBuildConfiguration", "name": "Staging", "buildSettings": [String: String]()],
            "PROJECT_CONFIGS": ["isa": "XCConfigurationList", "buildConfigurations": ["PROJECT_CONFIG"]],
            "PROJECT_CONFIG": ["isa": "XCBuildConfiguration", "name": "Staging", "buildSettings": ["DEVELOPMENT_TEAM": "ABCDEFGHIJ"]]
        ]
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["rootObject": "ROOT", "objects": objects], format: .xml, options: 0)
        try bytes.write(to: project.appendingPathComponent("project.pbxproj"))
        let session = root.appendingPathComponent("session")
        let manifest = try AutomationSourceSnapshot.capture(source: original, sessionRoot: session)
        let templates = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Integration/AutomationHost")
        let rebased = try AutomationHostGenerator.isolateProject(sessionRoot: session, projectRelativePath: "Subject.xcodeproj")
        XCTAssertEqual(rebased.digest, AutomationArtifactRegistry.digest(try Data(contentsOf: rebased.project.appendingPathComponent("project.pbxproj"))))
        let generated = try AutomationHostGenerator.associate(rebased: rebased, subjectTargetID: "APP", configuration: "Staging", subjectPlatform: "ios", templates: templates)
        XCTAssertEqual(generated.configuration, "Staging"); XCTAssertTrue(generated.projectPath.hasPrefix(session.path + "/source/"))
        XCTAssertTrue(generated.bundleID.hasSuffix(".xctrunner")); XCTAssertEqual(generated.templateDigest.count, 64)
        XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent("project.pbxproj")), bytes)
        try AutomationSourceSnapshot.verifyOriginal(manifest)
        let frozen = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: generated.projectPath).appendingPathComponent("project.pbxproj")), format: nil) as! [String: Any]
        let merged = frozen["objects"] as! [String: [String: Any]]
        let dateReference = try XCTUnwrap(merged.values.first { $0["isa"] as? String == "PBXFileReference" && $0["path"] as? String == "AutomationDateCodec.swift" })
        XCTAssertEqual(dateReference["lastKnownFileType"] as? String, "sourcecode.swift")
        let dateSources = merged.values.filter { $0["isa"] as? String == "PBXGroup" }.compactMap { $0["path"] as? String }.filter { $0.hasSuffix("/Sources") }
        XCTAssertEqual(dateSources.count, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dateSources[0]).appendingPathComponent("AutomationDateCodec.swift")), try Data(contentsOf: templates.appendingPathComponent("AutomationDateCodec.swift")))
        let durationReference = try XCTUnwrap(merged.values.first { $0["isa"] as? String == "PBXFileReference" && $0["path"] as? String == "AutomationDurationCodec.swift" })
        XCTAssertEqual(durationReference["sourceTree"] as? String, "<group>")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dateSources[0]).appendingPathComponent("AutomationDurationCodec.swift")), try Data(contentsOf: templates.appendingPathComponent("AutomationDurationCodec.swift")))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dateSources[0]).appendingPathComponent("AutomationCalendarCodec.swift")), try Data(contentsOf: templates.appendingPathComponent("AutomationCalendarCodec.swift")))
        let target = try XCTUnwrap(merged[generated.targetID]); XCTAssertEqual(target["productType"] as? String, "com.apple.product-type.bundle.ui-testing")
        let configs = merged.values.filter { $0["isa"] as? String == "XCBuildConfiguration" && ($0["buildSettings"] as? [String: Any])?["TEST_TARGET_NAME"] as? String == "Subject" }
        XCTAssertEqual(configs.count, 1); XCTAssertEqual((configs[0]["buildSettings"] as? [String: Any])?["DEVELOPMENT_TEAM"] as? String, "ABCDEFGHIJ")
        // Once Xcode or another task changes the inspected private project, the old receipt cannot create a host.
        XCTAssertThrowsError(try AutomationHostGenerator.associate(rebased: rebased, subjectTargetID: "APP", configuration: "Staging", subjectPlatform: "ios", templates: templates))
        XCTAssertThrowsError(try AutomationHostGenerator.associate(sessionRoot: session, projectRelativePath: "../original/Subject.xcodeproj", subjectTargetID: "APP", configuration: "Staging", subjectPlatform: "ios", templates: templates))
    }
}
