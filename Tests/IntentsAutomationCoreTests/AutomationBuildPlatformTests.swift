import XCTest
@testable import IntentsAutomationCore

final class AutomationBuildPlatformTests: XCTestCase {
    private let project = URL(fileURLWithPath: "/owned/source/App.xcodeproj")
    private let developer = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer")
    private func settings() -> [String: String] {
        ["TARGET_NAME": "Actual App", "CONFIGURATION": "Debug", "PROJECT_FILE_PATH": project.path,
         "PLATFORM_NAME": "iphoneos", "SDKROOT": developer.path + "/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk",
         "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator"]
    }
    private func resolve(_ settings: [String: String], target: String = "Actual App") throws -> AutomationBuildPlatform {
        let data = try JSONSerialization.data(withJSONObject: [["target": target, "buildSettings": settings]])
        return try AutomationBuildPlatform.read(data, project: project, targetName: "Actual App", configuration: "Debug", developer: developer)
    }
    func testActualResolvedSDKAndSupportedSimulatorAreRecorded() throws {
        let result = try resolve(settings())
        XCTAssertEqual(result.platformFamily, "ios"); XCTAssertTrue(result.supportsIOSSimulator)
        XCTAssertEqual(result.targetName, "Actual App"); XCTAssertEqual(result.projectPath, project.path)
        XCTAssertEqual(try JSONDecoder().decode(AutomationBuildPlatform.self, from: JSONEncoder().encode(result)), result)
    }
    func testResolvedModuleOverrideAndProductFallbackDoNotGuessTargetName() throws {
        XCTAssertNil(try resolve(settings()).swiftModuleName)
        var value = settings(); value["PRODUCT_MODULE_NAME"] = "Actual_App"
        XCTAssertEqual(try resolve(value).swiftModuleName, "Actual_App")
        value["SWIFT_MODULE_NAME"] = "CustomNamespace"
        XCTAssertEqual(try resolve(value).swiftModuleName, "CustomNamespace")
        value["SWIFT_MODULE_NAME"] = ""
        XCTAssertEqual(try resolve(value).swiftModuleName, "Actual_App")
        for bad in ["$(UNRESOLVED)", "Other.Module", "0Module", "bad:name", String(repeating: "a", count: 257)] {
            value["SWIFT_MODULE_NAME"] = bad; XCTAssertNil(try resolve(value).swiftModuleName)
        }
        value["SWIFT_MODULE_NAME"] = "Foreign"; value["TARGET_NAME"] = "ForeignTarget"
        XCTAssertThrowsError(try resolve(value))
    }
    func testSDKTempAliasMustResolveToTheSameActualFrozenProject() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let frozen = root.appendingPathComponent("App.xcodeproj")
        try FileManager.default.createDirectory(at: frozen, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var value = settings(); value["PROJECT_FILE_PATH"] = frozen.path
        let expected = try AutomationPath.canonical(frozen)
        let row: [String: Any] = ["target": "Actual App", "buildSettings": value]
        let result = try AutomationBuildPlatform.read(JSONSerialization.data(withJSONObject: [row]), project: expected,
            targetName: "Actual App", configuration: "Debug", developer: developer)
        XCTAssertEqual(result.projectPath, expected.path)
        value["PROJECT_FILE_PATH"] = expected.path + "\0/foreign.xcodeproj"
        XCTAssertThrowsError(try AutomationPath.canonical(URL(fileURLWithPath: value["PROJECT_FILE_PATH"]!)))
        XCTAssertThrowsError(try AutomationBuildPlatform.read(JSONSerialization.data(withJSONObject: [["target": "Actual App", "buildSettings": value]]),
            project: expected, targetName: "Actual App", configuration: "Debug", developer: developer))
        value["PROJECT_FILE_PATH"] = "/missing/App.xcodeproj"
        XCTAssertThrowsError(try AutomationBuildPlatform.read(JSONSerialization.data(withJSONObject: [["target": "Actual App", "buildSettings": value]]),
            project: expected, targetName: "Actual App", configuration: "Debug", developer: developer))
    }
    func testMacTargetRequiresExactResolvedNativePlatform() throws {
        var value = settings(); value["PLATFORM_NAME"] = "macosx"; value["SDKROOT"] = "macosx"; value["SUPPORTED_PLATFORMS"] = "macosx"
        let result = try resolve(value)
        XCTAssertEqual(result.platformFamily, "macos"); XCTAssertFalse(result.supportsIOSSimulator)
        XCTAssertTrue(result.supportsMacOS)
        XCTAssertFalse(try resolve(settings()).supportsMacOS)
    }
    func testForeignProjectTargetAndConfigurationCannotSupplyPlatform() throws {
        for (key, replacement) in [("PROJECT_FILE_PATH", "/live/App.xcodeproj"), ("TARGET_NAME", "Other"), ("CONFIGURATION", "Release")] {
            var value = settings(); value[key] = replacement; XCTAssertThrowsError(try resolve(value))
        }
        XCTAssertThrowsError(try resolve(settings(), target: "Other"))
    }
    func testAmbiguousMissingAndInconsistentSDKSettingsFailClosed() throws {
        let row: [String: Any] = ["target": "Actual App", "buildSettings": settings()]
        XCTAssertThrowsError(try AutomationBuildPlatform.read(JSONSerialization.data(withJSONObject: [row, row]),
            project: project, targetName: "Actual App", configuration: "Debug", developer: developer))
        for (key, replacement) in [("SDKROOT", "/external/iPhoneOS27.0.sdk"), ("SDKROOT", "macosx"),
                                    ("SUPPORTED_PLATFORMS", "iphonesimulator"), ("PLATFORM_NAME", "unknown")] {
            var value = settings(); value[key] = replacement; XCTAssertThrowsError(try resolve(value))
        }
        var missing = settings(); missing.removeValue(forKey: "SUPPORTED_PLATFORMS")
        XCTAssertThrowsError(try resolve(missing))
    }
}
