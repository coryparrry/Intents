#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationRepositoryCheckoutTests: XCTestCase {
    func testActualPublicHTTPSFetchRetainsRevision() async throws {
        guard ProcessInfo.processInfo.environment["INTENTS_REPOSITORY_FETCH_LIVE"] == "1" else { throw XCTSkip("Opt-in public HTTPS source fetch") }
        let root = URL(fileURLWithPath: "/private/tmp/repo-fetch-live-" + UUID().uuidString)
        print("Repository fetch evidence: " + root.path)
        let result = try await AutomationRepositoryCheckout.fetch("https://github.com/yonaskolb/XcodeGen.git", supportRoot: root)
        XCTAssertEqual(result.revision.count, 40)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.directory.appendingPathComponent("Package.swift").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.directory.deletingLastPathComponent().appendingPathComponent("checkout.json").path))
    }
    func testURLAdmissionRejectsCredentialsAndCommandTransports() throws {
        XCTAssertEqual(try AutomationRepositoryCheckout.validatedURL("https://example.com/team/app.git").host, "example.com")
        for address in ["file:///tmp/repo", "ssh://example.com/repo", "git@example.com:repo", "ext::sh -c touch", "--upload-pack=evil", "https://user:token@example.com/app", "https://example.com/app?token=secret", "https://example.com/app#branch", "https://example.com/", "https://example.com/app\n"] {
            XCTAssertThrowsError(try AutomationRepositoryCheckout.validatedURL(address), address)
        }
    }
    func testFetchUsesOwnedCheckoutAndDisablesHooksCredentialsAndOtherProtocols() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/repo-import-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("checkout")
        let args = AutomationRepositoryCheckout.arguments(url: URL(fileURLWithPath: "/tmp/forbidden-repository"), destination: destination)
        XCTAssertTrue(args.contains("core.hooksPath=/dev/null")); XCTAssertTrue(args.contains("credential.helper="))
        XCTAssertTrue(args.contains("submodule.recurse=false")); XCTAssertEqual(args.suffix(3).first, "--")
        let result = try await AutomationOwnedCommand().run(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: args,
            directory: root, environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"], timeout: .seconds(10))
        XCTAssertNotEqual(result.exitStatus, 0)
        XCTAssertTrue(String(decoding: result.stderr, as: UTF8.self).contains("transport 'file' not allowed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".git").path))
    }
}
#endif
