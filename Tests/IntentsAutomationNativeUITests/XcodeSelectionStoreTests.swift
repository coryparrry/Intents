#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

@MainActor final class XcodeSelectionStoreTests: XCTestCase {
    func testDefaultsRestoreIndependentlyAndRunOverrideDoesNotPersist() throws {
        let name = "XcodeSelectionStoreTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AutomationNativeXcodeSettings(defaults: defaults)
        let fallback = URL(fileURLWithPath: "/launch/Contents/Developer")
        settings.setPath("/Simulator Xcode.app", for: .simulator)
        settings.setPath("/Device Xcode.app/Contents/Developer", for: .physical)
        settings.setPath("/Mac Xcode.app", for: .macOS)
        for (destination, expected) in [(AutomationNativePreparationDestination.simulator, "/Simulator Xcode.app/Contents/Developer"),
                                       (.physical, "/Device Xcode.app/Contents/Developer"), (.macOS, "/Mac Xcode.app/Contents/Developer")] {
            XCTAssertEqual(settings.developerDirectory(for: destination, fallback: fallback).path, expected)
        }
        settings.runOverride = "  /Override Xcode.app  "
        XCTAssertEqual(settings.developerDirectory(for: .physical, fallback: fallback).path, "/Override Xcode.app/Contents/Developer")
        let restored = AutomationNativeXcodeSettings(defaults: defaults)
        XCTAssertEqual(restored.runOverride, "")
        XCTAssertEqual(restored.developerDirectory(for: .physical, fallback: fallback).path, "/Device Xcode.app/Contents/Developer")
        restored.setPath(" ", for: .physical)
        XCTAssertEqual(restored.developerDirectory(for: .physical, fallback: fallback), fallback)
        XCTAssertEqual(AutomationNativeXcodeSettings(defaults: defaults).path(for: .physical), "")
    }
    func testStoreUsesActualRequestTargetAndOverrideInvalidatesPendingSelection() throws {
        let name = "XcodeSelectionStoreTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AutomationNativeXcodeSettings(defaults: defaults)
        settings.setPath("/Device Xcode.app", for: .physical)
        settings.setPath("/Mac Xcode.app", for: .macOS)
        let model = AppAutomationStore(supportDirectory: URL(fileURLWithPath: "/private/tmp/xcode-selection-" + UUID().uuidString),
            developerDirectory: URL(fileURLWithPath: "/launch/Contents/Developer"), xcodeSettings: settings)
        defer { model.close() }
        XCTAssertEqual(model.developerDirectory(for: .init(id: "device", kind: .physical)).path, "/Device Xcode.app/Contents/Developer")
        let epoch = model.selectionEpoch
        model.runXcodePathOverride = "/Override Xcode.app"
        XCTAssertGreaterThan(model.selectionEpoch, epoch)
        XCTAssertEqual(model.developerDirectory(for: .init(id: "host-macos-local", kind: .nativeMac)).path, "/Override Xcode.app/Contents/Developer")
        XCTAssertEqual(settings.path(for: .macOS), "/Mac Xcode.app")
    }
}
#endif
