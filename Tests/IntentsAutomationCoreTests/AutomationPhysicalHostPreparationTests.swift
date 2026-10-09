#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationPhysicalHostPreparationTests: XCTestCase {
    private let target = TargetIdentity(id: "00008140-001049013EF3401C", kind: .physical)

    func testDevicePreparationPinsPhysicalSDKWithoutGrantingExecution() throws {
        let profile = try AutomationAssociatedHostPlatform(target: target)
        XCTAssertEqual(profile.sdkName, "iphoneos")
        XCTAssertEqual(profile.destination, "generic/platform=iOS")
        let project = URL(fileURLWithPath: "/owned/App.xcodeproj")
        var settings = ["TARGET_NAME": "App", "CONFIGURATION": "Debug", "PROJECT_FILE_PATH": project.path,
                        "PLATFORM_NAME": "iphoneos", "SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator"]
        func platform() throws -> AutomationBuildPlatform {
            try .read(JSONSerialization.data(withJSONObject: [["target": "App", "buildSettings": settings]]),
                      project: project, targetName: "App", configuration: "Debug",
                      developer: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"))
        }
        XCTAssertTrue(profile.accepts(try platform()))
        settings["PLATFORM_NAME"] = "iphonesimulator"; settings["SDKROOT"] = "iphonesimulator"
        XCTAssertFalse(profile.accepts(try platform()))
        XCTAssertThrowsError(try AutomationAssociatedHostPlatform(target: .init(id: "iPhone", kind: .physical)))
    }

    func testPhysicalHostResolutionRejectsSimulatorSubjectOrRunnerBytes() throws {
        let root = URL(fileURLWithPath: "/private/tmp/physical-host-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = root.appendingPathComponent("Debug-iphoneos/OwnedHost-Runner.app")
        let subject = root.appendingPathComponent("Debug-iphoneos/Subject.app")
        for (bundle, id) in [(host, "example.Host.xctrunner"), (subject, "example.Subject")] {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": id,
                "CFBundleExecutable": "App", "CFBundleSupportedPlatforms": ["iPhoneOS"]]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
            try AutomationPhysicalExecutableTests.binary().write(to: bundle.appendingPathComponent("App"))
        }
        try FileManager.default.createDirectory(at: host.appendingPathComponent("PlugIns/OwnedHost.xctest"), withIntermediateDirectories: true)
        let testBundle = host.appendingPathComponent("PlugIns/OwnedHost.xctest")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "OwnedHost"], format: .xml, options: 0)
            .write(to: testBundle.appendingPathComponent("Info.plist"))
        var testBinary = AutomationPhysicalExecutableTests.binary()
        AutomationPhysicalExecutableTests.write(8, at: 12, into: &testBinary)
        try testBinary.write(to: testBundle.appendingPathComponent("OwnedHost"))
        let entry: [String: Any] = ["BlueprintName": "OwnedHost", "IsUITestBundle": true,
            "TestHostPath": "__TESTROOT__/Debug-iphoneos/OwnedHost-Runner.app",
            "TestBundlePath": "__TESTHOST__/PlugIns/OwnedHost.xctest", "UITargetAppPath": "__TESTROOT__/Debug-iphoneos/Subject.app"]
        try PropertyListSerialization.data(fromPropertyList: ["OwnedHost": entry, "__xctestrun_metadata__": ["FormatVersion": 1]], format: .xml, options: 0)
            .write(to: root.appendingPathComponent("OwnedHost_iphoneos27.0-arm64.xctestrun"))
        let generated = AutomationGeneratedHost(projectPath: "unused", scheme: "OwnedHost", targetID: "HOST", bundleID: "example.Host.xctrunner",
            configuration: "Debug", templateDigest: String(repeating: "a", count: 64), subjectProductPath: subject.path, subjectBundleID: "example.Subject")
        let prepared = try AutomationPreparation.resolve(products: root, generated: generated, target: target)
        XCTAssertEqual(prepared.target, target)
        for platform in [UInt32(7), 1] {
            var foreign = testBinary; AutomationPhysicalExecutableTests.write(platform, at: 40, into: &foreign)
            try foreign.write(to: testBundle.appendingPathComponent("OwnedHost"))
            XCTAssertThrowsError(try AutomationPreparation.resolve(products: root, generated: generated, target: target))
        }
        try FileManager.default.removeItem(at: testBundle.appendingPathComponent("OwnedHost"))
        XCTAssertThrowsError(try AutomationPreparation.resolve(products: root, generated: generated, target: target))
        try testBinary.write(to: testBundle.appendingPathComponent("OwnedHost"))
        for bundle in [subject, host] {
            try AutomationPhysicalExecutableTests.binary(platform: 7).write(to: bundle.appendingPathComponent("App"))
            XCTAssertThrowsError(try AutomationPreparation.resolve(products: root, generated: generated, target: target))
            try AutomationPhysicalExecutableTests.binary().write(to: bundle.appendingPathComponent("App"))
        }
    }
}
#endif
