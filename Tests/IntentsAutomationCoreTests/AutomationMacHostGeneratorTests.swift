import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationMacHostGeneratorTests: XCTestCase {
    private func generatedSigningSettings(subject: [String: String], project: [String: String], macOS: Bool = true) throws -> [String: Any] {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("mac-host-signing-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        let fixture = try AutomationMacInputProbeFixture.write(at: original, sourceKind: .host)
        let projectFile = fixture.project.appendingPathComponent("project.pbxproj")
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: projectFile), format: nil) as? [String: Any])
        var objects = try XCTUnwrap(plist["objects"] as? [String: [String: Any]])
        let rootID = try XCTUnwrap(plist["rootObject"] as? String)
        for (owner, signing) in [(fixture.targetID, subject), (rootID, project)] {
            let list = try XCTUnwrap(objects[owner]?["buildConfigurationList"] as? String)
            let config = try XCTUnwrap((objects[list]?["buildConfigurations"] as? [String])?.first)
            var settings = try XCTUnwrap(objects[config]?["buildSettings"] as? [String: Any])
            for key in ["CODE_SIGN_STYLE", "CODE_SIGN_IDENTITY", "DEVELOPMENT_TEAM"] { settings.removeValue(forKey: key) }
            for (key, value) in signing { settings[key] = value }
            objects[config]?["buildSettings"] = settings
        }
        plist["objects"] = objects
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: projectFile)
        let session = root.appendingPathComponent("session")
        let manifest = try AutomationSourceSnapshot.capture(source: original, sessionRoot: session)
        let rebased = try AutomationHostGenerator.isolateProject(sessionRoot: session, projectRelativePath: "Subject.xcodeproj")
        let templates = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Integration/AutomationHost")
        let generated: AutomationGeneratedHost
        if macOS {
            let settings = ["TARGET_NAME": "Subject", "CONFIGURATION": "Debug", "PROJECT_FILE_PATH": rebased.project.path,
                            "PLATFORM_NAME": "macosx", "SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx"]
            let platform = try AutomationBuildPlatform.read(JSONSerialization.data(withJSONObject: [["target": "Subject", "buildSettings": settings]]),
                project: rebased.project, targetName: "Subject", configuration: "Debug", developer: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"))
            generated = try AutomationHostGenerator.associate(rebased: rebased, subjectTargetID: fixture.targetID,
                configuration: "Debug", platform: platform, templates: templates)
        } else {
            generated = try AutomationHostGenerator.associate(rebased: rebased, subjectTargetID: fixture.targetID,
                configuration: "Debug", subjectPlatform: "ios", templates: templates)
        }
        let merged = try XCTUnwrap((PropertyListSerialization.propertyList(from: Data(contentsOf: rebased.project.appendingPathComponent("project.pbxproj")), format: nil) as? [String: Any])?["objects"] as? [String: [String: Any]])
        let list = try XCTUnwrap(merged[generated.targetID]?["buildConfigurationList"] as? String)
        let config = try XCTUnwrap((merged[list]?["buildConfigurations"] as? [String])?.first)
        try AutomationSourceSnapshot.verifyOriginal(manifest)
        return try XCTUnwrap(merged[config]?["buildSettings"] as? [String: Any])
    }

    func testMacHostRetainsExplicitSubjectSigningBeforeProjectDefaults() throws {
        let identity = String(repeating: "A", count: 40)
        let settings = try generatedSigningSettings(
            subject: ["CODE_SIGN_STYLE": "Manual", "CODE_SIGN_IDENTITY": identity, "DEVELOPMENT_TEAM": "ABCDE12345"],
            project: ["CODE_SIGN_STYLE": "Automatic", "CODE_SIGN_IDENTITY": String(repeating: "B", count: 40), "DEVELOPMENT_TEAM": "OTHER12345"])
        XCTAssertEqual(settings["CODE_SIGN_STYLE"] as? String, "Manual")
        XCTAssertEqual(settings["CODE_SIGN_IDENTITY"] as? String, identity)
        XCTAssertEqual(settings["DEVELOPMENT_TEAM"] as? String, "ABCDE12345")
    }

    func testMacHostFallsBackToProjectSigningWhenSubjectDoesNotSpecifyIt() throws {
        let identity = String(repeating: "B", count: 40)
        let settings = try generatedSigningSettings(subject: [:],
            project: ["CODE_SIGN_STYLE": "Manual", "CODE_SIGN_IDENTITY": identity, "DEVELOPMENT_TEAM": "ABCDE12345"])
        XCTAssertEqual(settings["CODE_SIGN_STYLE"] as? String, "Manual")
        XCTAssertEqual(settings["CODE_SIGN_IDENTITY"] as? String, identity)
        XCTAssertEqual(settings["DEVELOPMENT_TEAM"] as? String, "ABCDE12345")
    }

    func testIOSHostKeepsAutomaticSigningWithoutCopyingMacIdentity() throws {
        let settings = try generatedSigningSettings(
            subject: ["CODE_SIGN_STYLE": "Manual", "CODE_SIGN_IDENTITY": String(repeating: "A", count: 40)],
            project: ["CODE_SIGN_STYLE": "Manual", "CODE_SIGN_IDENTITY": String(repeating: "B", count: 40)], macOS: false)
        XCTAssertEqual(settings["CODE_SIGN_STYLE"] as? String, "Automatic")
        XCTAssertNil(settings["CODE_SIGN_IDENTITY"])
        XCTAssertEqual(settings["SDKROOT"] as? String, "iphoneos")
    }

    func testResolvedMacHostRetainsSubjectAndHasNativeSettings() throws {
        let retained = ProcessInfo.processInfo.environment["INTENTS_MAC_HOST_FIXTURE_ROOT"].map { URL(fileURLWithPath: $0) }
        let root = (retained ?? URL(fileURLWithPath: "/private/tmp")).appendingPathComponent("mac-host-" + UUID().uuidString)
        defer { if retained == nil { try? FileManager.default.removeItem(at: root) } }
        let original = root.appendingPathComponent("original")
        let fixture = try AutomationMacInputProbeFixture.write(at: original, sourceKind: .host)
        let project = fixture.project, app = fixture.targetID, bytes = fixture.projectData
        let session = root.appendingPathComponent("session")
        let manifest = try AutomationSourceSnapshot.capture(source: original, sessionRoot: session)
        let rebased = try AutomationHostGenerator.isolateProject(sessionRoot: session, projectRelativePath: "Subject.xcodeproj")
        let templates = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Integration/AutomationHost")
        func platform(_ edits: [String: String] = [:]) throws -> AutomationBuildPlatform {
            var settings = ["TARGET_NAME": "Subject", "CONFIGURATION": "Debug", "PROJECT_FILE_PATH": rebased.project.path,
                            "PLATFORM_NAME": "macosx", "SDKROOT": "macosx", "SUPPORTED_PLATFORMS": "macosx"]
            settings.merge(edits) { _, new in new }
            return try AutomationBuildPlatform.read(JSONSerialization.data(withJSONObject: [["target": settings["TARGET_NAME"]!, "buildSettings": settings]]),
                project: URL(fileURLWithPath: settings["PROJECT_FILE_PATH"]!), targetName: settings["TARGET_NAME"]!, configuration: settings["CONFIGURATION"]!, developer: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"))
        }
        for edits in [["TARGET_NAME": "Other"], ["CONFIGURATION": "Release"], ["PROJECT_FILE_PATH": original.appendingPathComponent("Subject.xcodeproj").path],
                      ["PLATFORM_NAME": "appletvos", "SDKROOT": "appletvos", "SUPPORTED_PLATFORMS": "appletvos"]] {
            XCTAssertThrowsError(try AutomationHostGenerator.associate(rebased: rebased, subjectTargetID: app, configuration: "Debug", platform: platform(edits), templates: templates))
        }
        XCTAssertThrowsError(try AutomationHostGenerator.associate(rebased: rebased, subjectTargetID: app, configuration: "Debug", subjectPlatform: "macos", templates: templates))
        let generated = try AutomationHostGenerator.associate(rebased: rebased, subjectTargetID: app, configuration: "Debug", platform: platform(), templates: templates)
        let merged = try XCTUnwrap((PropertyListSerialization.propertyList(from: Data(contentsOf: rebased.project.appendingPathComponent("project.pbxproj")), format: nil) as? [String: Any])?["objects"] as? [String: [String: Any]])
        let target = try XCTUnwrap(merged[generated.targetID])
        let list = try XCTUnwrap(target["buildConfigurationList"] as? String)
        let config = try XCTUnwrap((merged[list]?["buildConfigurations"] as? [String])?.first)
        let settings = try XCTUnwrap(merged[config]?["buildSettings"] as? [String: Any])
        XCTAssertEqual(settings["SDKROOT"] as? String, "macosx")
        XCTAssertEqual(settings["SUPPORTED_PLATFORMS"] as? String, "macosx")
        XCTAssertEqual(settings["MACOSX_DEPLOYMENT_TARGET"] as? String, "27.0")
        XCTAssertEqual(settings["TEST_TARGET_NAME"] as? String, "Subject")
        XCTAssertNil(settings["IPHONEOS_DEPLOYMENT_TARGET"]); XCTAssertNil(settings["TARGETED_DEVICE_FAMILY"])
        let dependency = try XCTUnwrap((target["dependencies"] as? [String])?.first)
        XCTAssertEqual(merged[dependency]?["target"] as? String, app)
        XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent("project.pbxproj")), bytes)
        try AutomationSourceSnapshot.verifyOriginal(manifest)
        XCTAssertThrowsError(try AutomationHostGenerator.associate(rebased: rebased, subjectTargetID: app, configuration: "Debug", platform: platform(), templates: templates))
        if retained != nil { try JSONEncoder().encode(generated).write(to: root.appendingPathComponent("generated-host.json")) }
    }
}
