#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationPreparedApplicationRecordTests: XCTestCase {
    private func fixture() throws -> (URL, URL, AutomationPreparedApplication) {
        let root = URL(fileURLWithPath: "/private/tmp/owned-preparation-record-" + UUID().uuidString)
        let session = root.appendingPathComponent("prepare-" + UUID().uuidString)
        let product = session.appendingPathComponent("DerivedData/Products/Subject.app")
        try FileManager.default.createDirectory(at: product, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = AutomationSourceManifest(sourceRoot: root.appendingPathComponent("Source").path, files: [], directories: [], excludedPaths: [])
        var app = AppIdentity(logicalID: "example.Source#APP", bundleID: "example.Subject", platform: "ios", productDigest: String(repeating: "a", count: 64))
        app.canonicalBundlePath = product.path; app.sourceManifestDigest = try source.digest; app.configuration = "Debug"
        let prepared = AutomationPreparedApplication(source: source,
            generatedHost: .init(projectPath: "unused", scheme: "unused", targetID: "HOST", bundleID: "unused", configuration: "Debug", templateDigest: String(repeating: "b", count: 64)),
            host: .init(app: app, target: .init(id: UUID().uuidString, kind: .simulator), xctestrunPath: "unused", xctestrunDigest: String(repeating: "c", count: 64), subjectProductPath: product.path, hostBundlePath: "unused", hostProductDigest: String(repeating: "d", count: 64), hostBundleID: "unused", testTarget: "unused"),
            catalog: .init(app: app, systemActions: [], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: []), buildLogPath: "unused", buildLogTruncated: false)
        let record = session.appendingPathComponent("prepared-application.json")
        try JSONEncoder().encode(prepared).write(to: record)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
        return (root, record, prepared)
    }
    func testLoadsOnlyExactOwnedPreparation() throws {
        let (root, _, prepared) = try fixture()
        XCTAssertEqual(try AutomationPreparedApplicationRecord.load(app: prepared.host.app, supportRoot: root), prepared)
        var other = prepared.host.app; other.productDigest = String(repeating: "e", count: 64)
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: other, supportRoot: root))
    }
    func testRejectsTraversalAndProductSymlink() throws {
        let (root, record, prepared) = try fixture()
        var alias = prepared
        alias.host.app.canonicalBundlePath = record.deletingLastPathComponent().path + "/DerivedData/Products/../Products/Subject.app"
        alias.host.subjectProductPath = alias.host.app.canonicalBundlePath!; alias.catalog.app = alias.host.app
        try JSONEncoder().encode(alias).write(to: record)
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: alias.host.app, supportRoot: root))
        let product = URL(fileURLWithPath: prepared.host.subjectProductPath), outside = root.appendingPathComponent("Outside.app")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: product)
        try FileManager.default.createSymbolicLink(at: product, withDestinationURL: outside)
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: prepared.host.app, supportRoot: root))
    }
    func testRejectsWritableRecordDirectoryAndHardLink() throws {
        let (root, record, prepared) = try fixture()
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: record.path)
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: prepared.host.app, supportRoot: root))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
        let session = record.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o770], ofItemAtPath: session.path)
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: prepared.host.app, supportRoot: root))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: session.path)
        try FileManager.default.linkItem(at: record, to: session.appendingPathComponent("record-copy"))
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: prepared.host.app, supportRoot: root))
    }
    func testRejectsRecordSymlinkCorruptOversizeAndSourceDrift() throws {
        let (root, record, prepared) = try fixture()
        var drift = prepared; drift.source.excludedPaths = ["changed"]
        try JSONEncoder().encode(drift).write(to: record)
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: prepared.host.app, supportRoot: root))
        try Data("corrupt".utf8).write(to: record)
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: prepared.host.app, supportRoot: root))
        let handle = try FileHandle(forWritingTo: record); try handle.truncate(atOffset: 16 * 1024 * 1024 + 1); try handle.close()
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: prepared.host.app, supportRoot: root))
        let actual = record.deletingLastPathComponent().appendingPathComponent("actual.json")
        try FileManager.default.moveItem(at: record, to: actual); try FileManager.default.createSymbolicLink(at: record, withDestinationURL: actual)
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: prepared.host.app, supportRoot: root))
    }
}
#endif
