import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationMacSigningGeneratorTests: XCTestCase {
    func testMacHostPreservesExplicitSubjectSigningOverProjectDefaults() throws {
        let identity = String(repeating: "A", count: 40)
        let settings = try generatedSettings(mac: true,
            subject: ["DEVELOPMENT_TEAM": "ABCDE12345", "CODE_SIGN_STYLE": "Manual", "CODE_SIGN_IDENTITY": identity],
            project: ["DEVELOPMENT_TEAM": "OTHER12345", "CODE_SIGN_STYLE": "Automatic", "CODE_SIGN_IDENTITY": "Other"])
        XCTAssertEqual(settings["DEVELOPMENT_TEAM"] as? String, "ABCDE12345")
        XCTAssertEqual(settings["CODE_SIGN_STYLE"] as? String, "Manual")
        XCTAssertEqual(settings["CODE_SIGN_IDENTITY"] as? String, identity)
    }

    func testMacHostInheritsProjectSigningWhenSubjectHasNoOverride() throws {
        let settings = try generatedSettings(mac: true, project:
            ["DEVELOPMENT_TEAM": "ABCDE12345", "CODE_SIGN_STYLE": "Manual", "CODE_SIGN_IDENTITY": "Apple Development"])
        XCTAssertEqual(settings["DEVELOPMENT_TEAM"] as? String, "ABCDE12345")
        XCTAssertEqual(settings["CODE_SIGN_STYLE"] as? String, "Manual")
        XCTAssertEqual(settings["CODE_SIGN_IDENTITY"] as? String, "Apple Development")
    }

    func testMacHostExplicitAutomaticStyleOverridesManualProjectStyle() throws {
        let settings = try generatedSettings(mac: true, subject: ["CODE_SIGN_STYLE": "Automatic"],
            project: ["CODE_SIGN_STYLE": "Manual"])
        XCTAssertEqual(settings["CODE_SIGN_STYLE"] as? String, "Automatic")
    }

    func testUnsignedMacUIHostKeepsAutomaticDefaultWithoutClaimingTeam() throws {
        let settings = try generatedSettings(mac: true)
        XCTAssertEqual(settings["CODE_SIGN_STYLE"] as? String, "Automatic")
        XCTAssertNil(settings["DEVELOPMENT_TEAM"])
        XCTAssertNil(settings["CODE_SIGN_IDENTITY"])
    }

    func testIOSHostSigningBehaviorIsUnchanged() throws {
        let settings = try generatedSettings(mac: false, subject:
            ["DEVELOPMENT_TEAM": "ABCDE12345", "CODE_SIGN_STYLE": "Manual", "CODE_SIGN_IDENTITY": "Apple Development"])
        XCTAssertEqual(settings["DEVELOPMENT_TEAM"] as? String, "ABCDE12345")
        XCTAssertEqual(settings["CODE_SIGN_STYLE"] as? String, "Automatic")
        XCTAssertNil(settings["CODE_SIGN_IDENTITY"])
    }

    private func generatedSettings(mac: Bool, subject: [String: String] = [:], project: [String: String] = [:]) throws -> [String: Any] {
        let root = URL(fileURLWithPath: "/private/tmp/mac-signing-generator-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        let fixture = try AutomationMacInputProbeFixture.write(at: original, sourceKind: .host)
        let file = fixture.project.appendingPathComponent("project.pbxproj")
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        var objects = try XCTUnwrap(plist["objects"] as? [String: [String: Any]])
        let projectID = try XCTUnwrap(plist["rootObject"] as? String)
        for (owner, updates) in [(fixture.targetID, subject), (projectID, project)] {
            let list = try XCTUnwrap(objects[owner]?["buildConfigurationList"] as? String)
            for config in try XCTUnwrap(objects[list]?["buildConfigurations"] as? [String]) {
                var settings = objects[config]?["buildSettings"] as? [String: Any] ?? [:]
                // The shared probe fixture sets Automatic on its app target.
                // Each scenario declares its complete signing overrides here.
                for key in ["DEVELOPMENT_TEAM", "CODE_SIGN_STYLE", "CODE_SIGN_IDENTITY"] { settings.removeValue(forKey: key) }
                for (key, value) in updates { settings[key] = value }
                objects[config]?["buildSettings"] = settings
            }
        }
        plist["objects"] = objects
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: file)
        let sourceBytes = try Data(contentsOf: file)
        let session = root.appendingPathComponent("session")
        _ = try AutomationSourceSnapshot.capture(source: original, sessionRoot: session)
        let rebased = try AutomationHostGenerator.isolateProject(sessionRoot: session, projectRelativePath: "Subject.xcodeproj")
        let templates = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Integration/AutomationHost")
        let generated: AutomationGeneratedHost
        if mac {
            let platform = AutomationBuildPlatform(targetName: "Subject", configuration: "Debug", projectPath: rebased.project.path,
                platformName: "macosx", platformFamily: "macos", sdkRoot: "macosx", supportedPlatforms: ["macosx"])
            generated = try AutomationHostGenerator.associate(rebased: rebased, subjectTargetID: fixture.targetID,
                configuration: "Debug", platform: platform, templates: templates)
        } else {
            generated = try AutomationHostGenerator.associate(rebased: rebased, subjectTargetID: fixture.targetID,
                configuration: "Debug", subjectPlatform: "ios", templates: templates)
        }
        XCTAssertEqual(try Data(contentsOf: file), sourceBytes)
        let merged = try XCTUnwrap((PropertyListSerialization.propertyList(from: Data(contentsOf: rebased.project.appendingPathComponent("project.pbxproj")), format: nil) as? [String: Any])?["objects"] as? [String: [String: Any]])
        let list = try XCTUnwrap(merged[generated.targetID]?["buildConfigurationList"] as? String)
        let config = try XCTUnwrap((merged[list]?["buildConfigurations"] as? [String])?.first)
        return try XCTUnwrap(merged[config]?["buildSettings"] as? [String: Any])
    }
}
