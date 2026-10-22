import Foundation
import Testing
@testable import MacIntentTesting

struct MacIntentProductIdentityTests {
    @Test func publicDynamicCodeValidationRejectsADifferentExecutingBuild() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["10"]
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        let selected = try MacIntentCodeIdentity(appURL: URL(fileURLWithPath: "/bin/sleep"))
        try selected.validate(processIdentifier: child.processIdentifier)
        let different = try MacIntentCodeIdentity(appURL: URL(fileURLWithPath: "/bin/echo"))
        #expect(throws: MacIntentTestingError.self) { try different.validate(processIdentifier: child.processIdentifier) }
    }

    @Test func unchangedMetadataDoesNotHideExecutableOrResourceReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-intent-product-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("executable")
        let metadata = root.appendingPathComponent("extract.actionsdata")
        try Data("first build".utf8).write(to: executable)
        try Data("unchanged declarations".utf8).write(to: metadata)
        let selected = try MacIntentProductIdentity.capture(root)
        try selected.validate()
        try Data("fixed build".utf8).write(to: executable, options: .atomic)
        #expect(try MacIntentProductIdentity.capture(root) != selected)
        #expect(throws: MacIntentTestingError.self) { try selected.validate() }
        let fixed = try MacIntentProductIdentity.capture(root)
        try Data("new resource".utf8).write(to: root.appendingPathComponent("resource"))
        #expect(throws: MacIntentTestingError.self) { try fixed.validate() }
    }

    @Test func externalBundleLinksCannotSupplyUnfrozenCode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-intent-link-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("external"), withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        #expect(throws: MacIntentTestingError.self) { try MacIntentProductIdentity.capture(root) }
    }
}
