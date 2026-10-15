import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationBuiltProductAdmissionTests: XCTestCase {
    func testMissingEmbeddedExtensionVersionRetainsPrecisePackagingGapAndNeverRepairs() throws {
        let root = URL(fileURLWithPath: "/private/tmp/extension-admission-" + UUID().uuidString)
        let extensionURL = root.appendingPathComponent("Subject.app/PlugIns/TaskWidget.appex")
        try FileManager.default.createDirectory(at: extensionURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "example.widget"], format: .xml, options: 0)
        let info = extensionURL.appendingPathComponent("Info.plist"); try plist.write(to: info)
        XCTAssertThrowsError(try AutomationBuiltProductAdmission.validateEmbeddedExtensions(bundle: root.appendingPathComponent("Subject.app"), macOS: false)) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.contains("TaskWidget.appex")); XCTAssertTrue(text.contains("CFBundleVersion"))
            XCTAssertTrue(text.contains("compiled"))
        }
        XCTAssertEqual(try Data(contentsOf: info), plist)
    }
    func testValidVersionsPassForIOSAndMacOSLayouts() throws {
        for macOS in [false, true] {
            let root = URL(fileURLWithPath: "/private/tmp/extension-admission-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let bundle = root.appendingPathComponent("Subject.app")
            let info = bundle.appendingPathComponent(macOS ? "Contents/PlugIns/Widget.appex/Contents/Info.plist" : "PlugIns/Widget.appex/Info.plist")
            try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": "1", "CFBundleShortVersionString": "1.0.0"], format: .xml, options: 0).write(to: info)
            XCTAssertNoThrow(try AutomationBuiltProductAdmission.validateEmbeddedExtensions(bundle: bundle, macOS: macOS))
        }
    }
}
