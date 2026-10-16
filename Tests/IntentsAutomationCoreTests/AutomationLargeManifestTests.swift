#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationLargeManifestTests: XCTestCase {
    private func fixture() throws -> (URL, URL, AutomationPreparedApplication) {
        let root = URL(fileURLWithPath: "/private/tmp/large-preparation-" + UUID().uuidString)
        let session = root.appendingPathComponent("prepare-" + UUID().uuidString)
        let product = session.appendingPathComponent("DerivedData/Products/Subject.app")
        try FileManager.default.createDirectory(at: product, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        // 18,000 bounded metadata entries model dependency-tree path overhead;
        // only the two records and one product directory are written to disk.
        let prefix = String(repeating: "dependency/", count: 85)
        let source = AutomationSourceManifest(sourceRoot: root.appendingPathComponent("Source").path,
            files: [], directories: [], excludedPaths: (0..<18_000).map { prefix + String(format: "%05d", $0) })
        var app = AppIdentity(logicalID: "example.Source#APP", bundleID: "example.Subject", platform: "ios", productDigest: String(repeating: "a", count: 64))
        app.canonicalBundlePath = product.path
        app.sourceManifestDigest = try source.digest
        app.configuration = "Debug"
        let prepared = AutomationPreparedApplication(source: source,
            generatedHost: .init(projectPath: "unused", scheme: "unused", targetID: "HOST", bundleID: "unused", configuration: "Debug", templateDigest: String(repeating: "b", count: 64)),
            host: .init(app: app, target: .init(id: UUID().uuidString, kind: .simulator), xctestrunPath: "unused", xctestrunDigest: String(repeating: "c", count: 64), subjectProductPath: product.path, hostBundlePath: "unused", hostProductDigest: String(repeating: "d", count: 64), hostBundleID: "unused", testTarget: "unused"),
            catalog: .init(app: app, systemActions: [], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: []), buildLogPath: "unused", buildLogTruncated: false)
        return (root, session, prepared)
    }

    func testLargeSourceManifestWriterAndEmbeddedPreparedRecordReplay() throws {
        let (root, session, prepared) = try fixture()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestBytes = try encoder.encode(prepared.source)
        XCTAssertGreaterThan(manifestBytes.count, 16 * 1024 * 1024)
        XCTAssertLessThan(manifestBytes.count, AutomationSourceSnapshot.maximumManifestBytes)
        let sourceStore = try AutomationSourceSnapshot.manifestStore(sessionRoot: session)
        try sourceStore.withLock { try sourceStore.write(manifestBytes) }
        let replay = try AutomationReadOnlyFile.read(root: session, relativePath: "source-manifest.json", maximumBytes: AutomationSourceSnapshot.maximumManifestBytes)
        XCTAssertEqual(try JSONDecoder().decode(AutomationSourceManifest.self, from: replay), prepared.source)
        let recordBytes = try encoder.encode(prepared)
        XCTAssertGreaterThan(recordBytes.count, 16 * 1024 * 1024)
        let record = try AutomationDurableFile(url: session.appendingPathComponent("prepared-application.json"), maximumBytes: AutomationPreparedApplicationRecord.maximumRecordBytes)
        try record.withLock { try record.write(recordBytes) }
        XCTAssertEqual(try AutomationPreparedApplicationRecord.load(app: prepared.host.app, supportRoot: root), prepared)
    }

    func testSourceManifestAndPreparedRecordKeepBoundedSizeLimits() throws {
        let (root, session, prepared) = try fixture()
        let sourceStore = try AutomationSourceSnapshot.manifestStore(sessionRoot: session)
        XCTAssertThrowsError(try sourceStore.withLock {
            try sourceStore.write(Data(count: AutomationSourceSnapshot.maximumManifestBytes + 1))
        })
        let recordURL = session.appendingPathComponent("prepared-application.json")
        _ = FileManager.default.createFile(atPath: recordURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: recordURL)
        try handle.truncate(atOffset: UInt64(AutomationPreparedApplicationRecord.maximumRecordBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try AutomationPreparedApplicationRecord.load(app: prepared.host.app, supportRoot: root))
    }
}
#endif
