import XCTest
@testable import IntentsAutomationCore

final class AutomationXcodeSDKCompatibilityTests: XCTestCase {
    private let developer = URL(fileURLWithPath: "/Applications/Xcode Test.app/Contents/Developer")
    private let device = TargetIdentity(id: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", kind: .physical)
    private let mac = TargetIdentity(id: "host-macos-local", kind: .nativeMac, loginSession: "test")

    func testMatchingMajorMinorAllowsPatchVersionsAndBuildSuffix() throws {
        try AutomationXcodeSDKCompatibility.validate(target: device, targetOSVersion: "27.0.1 (24A123)", sdkVersion: "27.0\n", developerDirectory: developer)
        try AutomationXcodeSDKCompatibility.validate(target: mac, targetOSVersion: "27.1.2", sdkVersion: "27.1", developerDirectory: developer)
    }
    func testDeviceAndMacMismatchExplainNeededXcodeAndCurrentSDK() {
        for (target, platform) in [(device, "iOS"), (mac, "macOS")] {
            XCTAssertThrowsError(try AutomationXcodeSDKCompatibility.validate(target: target, targetOSVersion: "27.1", sdkVersion: "27.0", developerDirectory: developer)) { error in
                guard case AutomationContractError.missingEvidence(let message) = error else { return XCTFail("Unexpected error: \(error)") }
                XCTAssertEqual(message, "Install Xcode matching " + platform + " 27.1 (current: " + platform + " SDK 27.0 at " + self.developer.path + ").")
            }
        }
    }
    func testUnknownVersionDoesNotInventAnOSMismatch() {
        XCTAssertThrowsError(try AutomationXcodeSDKCompatibility.validate(target: device, targetOSVersion: "Unknown version", sdkVersion: "27.0", developerDirectory: developer)) { error in
            guard case AutomationContractError.missingEvidence(let message) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue(message.contains("Could not determine the iOS version"))
        }
    }
    func testSimulatorPreparationDoesNotRequireHostOSMatching() throws {
        try AutomationXcodeSDKCompatibility.validate(target: .init(id: UUID().uuidString, kind: .simulator),
            targetOSVersion: "26.0", sdkVersion: "27.0", developerDirectory: developer)
    }
}
