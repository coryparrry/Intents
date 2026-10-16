#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

enum AutomationServedJavaScriptTestEvidence {
    /// Preserve only bounded diagnostics; no customer sources, bundle bodies,
    /// runtime executables or private Metro authorization tokens are copied.
    static func retain(root: URL, evidenceRoot: URL, error: any Error) throws -> URL {
        let destination = evidenceRoot.appendingPathComponent("served-js-failure-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try AutomationDurableFile(url: destination.appendingPathComponent("test-error.txt"), maximumBytes: 4096)
            .write(Data(String(String(describing: error).prefix(2048)).utf8))
        let sessions = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("served-js-") }.sorted { $0.path < $1.path }
        guard sessions.count <= 8 else { throw AutomationContractError.invalidIdentity }
        for session in sessions {
            guard try AutomationPath.canonical(session).path == session.path else { throw AutomationContractError.invalidIdentity }
            for (name, limit) in [("server.log", 4_194_304), ("failure.json", 16_384), ("openssl.cnf", 4096)] {
                let file = session.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let data = try AutomationReadOnlyFile.read(file, maximumBytes: limit)
                try AutomationDurableFile(url: destination.appendingPathComponent(session.lastPathComponent).appendingPathComponent(name), maximumBytes: limit).write(data)
            }
        }
        return destination
    }
}

final class AutomationServedJavaScriptTestEvidenceTests: XCTestCase {
    func testFailureEvidenceSurvivesFixtureRemovalWithoutCopyingSourceOrTokens() throws {
        let root = URL(fileURLWithPath: "/private/tmp/intents-js-evidence-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("fixture"), session = fixture.appendingPathComponent("served-js-one")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("owned stderr".utf8).write(to: session.appendingPathComponent("server.log"))
        try Data("{\"stage\":\"verify-initial-response\"}".utf8).write(to: session.appendingPathComponent("failure.json"))
        try Data("private-token".utf8).write(to: session.appendingPathComponent("metro-spec.json"))
        let saved = try AutomationServedJavaScriptTestEvidence.retain(root: fixture, evidenceRoot: root.appendingPathComponent("retained"), error: AutomationContractError.invalidIdentity)
        try FileManager.default.removeItem(at: fixture)
        XCTAssertEqual(try String(contentsOf: saved.appendingPathComponent("served-js-one/server.log"), encoding: .utf8), "owned stderr")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.appendingPathComponent("served-js-one/failure.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.appendingPathComponent("served-js-one/metro-spec.json").path))
    }
}
#endif
