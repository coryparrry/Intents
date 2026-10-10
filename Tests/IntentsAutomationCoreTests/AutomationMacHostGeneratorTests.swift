import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationMacHostGeneratorTests: XCTestCase {
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
