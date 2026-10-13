import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationXCUITestGeneratorTests: XCTestCase {
    func testDebugHostGenerationNeedsNoDevelopmentTeamAndIncludesUISteps() throws {
        let root = URL(fileURLWithPath: "/private/tmp/xcuitest-generator-" + UUID().uuidString)
        let source = root.appendingPathComponent("original"), project = source.appendingPathComponent("Subject.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let objects: [String: Any] = [
            "ROOT": ["isa": "PBXProject", "mainGroup": "MAIN", "productRefGroup": "PRODUCTS", "targets": ["APP"], "buildConfigurationList": "PROJECT_CONFIGS"],
            "MAIN": ["isa": "PBXGroup", "children": ["PRODUCTS"]], "PRODUCTS": ["isa": "PBXGroup", "children": [String]()],
            "APP": ["isa": "PBXNativeTarget", "name": "Subject", "productType": "com.apple.product-type.application", "buildConfigurationList": "APP_CONFIGS"],
            "APP_CONFIGS": ["isa": "XCConfigurationList", "buildConfigurations": ["APP_CONFIG"]],
            "APP_CONFIG": ["isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": [String: String]()],
            "PROJECT_CONFIGS": ["isa": "XCConfigurationList", "buildConfigurations": ["PROJECT_CONFIG"]],
            "PROJECT_CONFIG": ["isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": [String: String]()]
        ]
        try PropertyListSerialization.data(fromPropertyList: ["rootObject": "ROOT", "objects": objects], format: .xml, options: 0)
            .write(to: project.appendingPathComponent("project.pbxproj"))
        let session = root.appendingPathComponent("session")
        _ = try AutomationSourceSnapshot.capture(source: source, sessionRoot: session)
        let templates = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Integration/AutomationHost")
        let generated = try AutomationHostGenerator.associate(sessionRoot: session, projectRelativePath: "Subject.xcodeproj",
            subjectTargetID: "APP", configuration: "Debug", subjectPlatform: "ios", templates: templates)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: generated.projectPath)
            .appendingPathComponent("project.pbxproj")), format: nil) as? [String: Any])
        let merged = try XCTUnwrap(plist["objects"] as? [String: [String: Any]])
        let config = try XCTUnwrap(merged.values.first { ($0["buildSettings"] as? [String: Any])?["TEST_TARGET_NAME"] as? String == "Subject" })
        let settings = try XCTUnwrap(config["buildSettings"] as? [String: Any])
        XCTAssertNil(settings["DEVELOPMENT_TEAM"])
        XCTAssertEqual(config["name"] as? String, "Debug")
        XCTAssertTrue(merged.values.contains { $0["path"] as? String == "UIStepTests.swift" })
        XCTAssertTrue(merged.values.contains { $0["path"] as? String == "UIHostPlan.swift" })
        try AutomationHostGenerator.verifyGeneratedSources(generated, sessionRoot: session)
    }
}
