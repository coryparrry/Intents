#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore
@testable import IntentsAutomationNativeUI

@MainActor final class RecentApplicationRecoveryTests: XCTestCase {
    func testPickerAliasIsCanonicalizedWithoutRestoringApproval() async throws {
        let (model, root, app) = try await InstalledUIStoreTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = URL(fileURLWithPath: app.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/"))
        model.select(alias); await model.task?.value
        XCTAssertEqual(model.candidate?.containerPath, app.path)
        XCTAssertEqual(model.recentApplications.first?.path, app.path)
        XCTAssertFalse(model.effectsConfirmed)
    }
    func testNativeIPASelectionCompletesAndRemembersOriginalArchive() async throws {
        let (model, root, app) = try await InstalledUIStoreTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = root.appendingPathComponent("Payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: app, to: payload.appendingPathComponent("Subject.app"))
        let archive = root.appendingPathComponent("Subject.ipa"), process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); process.arguments = ["-q", "-r", archive.path, "Payload"]; process.currentDirectoryURL = root
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        model.select(archive)
        XCTAssertTrue(model.busy)
        await model.task?.value
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.recentApplications.first?.path, archive.path)
        XCTAssertEqual(model.candidate?.app?.bundleID, "example.Selected")
        XCTAssertTrue(try XCTUnwrap(model.candidate?.containerPath).contains("ImportedApplications"))
        XCTAssertFalse(model.effectsConfirmed)
        XCTAssertNil(model.report)
        let bad = root.appendingPathComponent("damaged.ipa"); try Data("bad".utf8).write(to: bad)
        model.select(bad); await model.task?.value
        XCTAssertFalse(model.busy)
        XCTAssertNotNil(model.message)
        XCTAssertFalse(model.recentApplications.contains { $0.path == bad.path })
    }
    func testReopeningPersistedSelectionReinspectsAndDoesNotRestoreApproval() async throws {
        let (original, root, app) = try await InstalledUIStoreTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(original.recentApplications.count, 1)
        let reopened = AppAutomationStore(supportDirectory: root.appendingPathComponent("support"))
        XCTAssertNil(reopened.intake)
        let recent = try XCTUnwrap(reopened.recentApplications.first)
        let infoURL = app.appendingPathComponent("Info.plist")
        var info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any])
        info["CFBundleIdentifier"] = "example.Reinspected"
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: infoURL)
        reopened.reopenApplication(recent); await reopened.task?.value
        XCTAssertEqual(reopened.candidate?.app?.bundleID, "example.Reinspected")
        XCTAssertFalse(reopened.effectsConfirmed)
        XCTAssertNil(reopened.prepared)
        XCTAssertNil(reopened.report)
        XCTAssertFalse(reopened.busy)
        XCTAssertEqual(reopened.recentApplications.count, 1)
        reopened.forgetApplication(try XCTUnwrap(reopened.recentApplications.first))
        XCTAssertTrue(try AutomationRecentApplicationStore(supportRoot: reopened.support).read().isEmpty)
        XCTAssertNotNil(reopened.intake, "Forgetting history must not clear the selected app")
    }
    func testHistoryIsBoundedAndRejectsCorruptOrLinkedStorage() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/recent-apps-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AutomationRecentApplicationStore(supportRoot: root)
        for index in 0..<12 { try store.remember(.init(path: "/apps/\(index).app", name: "App \(index)", bookmark: nil)) }
        XCTAssertEqual(try store.read().count, 10)
        XCTAssertEqual(try store.read().first?.path, "/apps/11.app")
        try store.remember(.init(path: "/apps/4.app", name: "Moved up", bookmark: nil))
        XCTAssertEqual(try store.read().count, 10)
        XCTAssertEqual(try store.read().first?.name, "Moved up")
        XCTAssertThrowsError(try store.remember(.init(path: "relative", name: "App", bookmark: nil)))
        XCTAssertThrowsError(try store.remember(.init(path: "/app", name: "App", bookmark: Data(count: 65_537))))
        let file = root.appendingPathComponent("recent-applications.json")
        try Data("{}".utf8).write(to: file)
        XCTAssertThrowsError(try store.read())
        let model = AppAutomationStore(supportDirectory: root)
        XCTAssertNotNil(model.recentApplicationsError)
        XCTAssertFalse(model.busy)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("outside.json"))
        XCTAssertThrowsError(try store.remember(.init(path: "/app", name: "App", bookmark: nil)))
    }
}
#endif
