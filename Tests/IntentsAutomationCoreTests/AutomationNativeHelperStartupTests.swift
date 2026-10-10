#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

@MainActor
final class AutomationNativeHelperStartupTests: XCTestCase {
    private struct Receipt: Decodable {
        var helperABI: String
        var customerRuntimeEnabled: Bool
        var hardwareQualified: Bool
        var helperPath: String
        var helperSHA256: String
    }
    private struct Reply: Decodable {
        struct Probe: Decodable {
            var scope: String
            var uiInteracted: Bool
            var identity: AutomationProcessIdentity
        }
        var ok: Bool
        var data: Probe
    }
    func testActualPinnedNativeHelperAcknowledgesItsIdentityWithoutUI() async throws {
        guard ProcessInfo.processInfo.environment["INTENTS_MAC_GATED_HELPER_PROBE"] == "1" else {
            throw XCTSkip("No explicit startup-only native helper qualification")
        }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let receiptBytes = try Data(contentsOf: repository.appendingPathComponent("Verification/Automation/private-mac-startup-helper-release-1.json"))
        guard AutomationArtifactRegistry.digest(receiptBytes) == "065761b76888943adba6e378ddcdc1cd3d9594f479a577072197bd58afbbb9c6" else {
            return XCTFail("Pinned release receipt differs")
        }
        let receipt = try JSONDecoder().decode(Receipt.self, from: receiptBytes)
        guard receipt.helperABI == "startup-gate-v1", !receipt.customerRuntimeEnabled, !receipt.hardwareQualified else {
            return XCTFail("Helper startup ABI boundary differs")
        }
        let helper = try AutomationPath.canonical(URL(fileURLWithPath: receipt.helperPath))
        guard helper.path == receipt.helperPath else { return XCTFail("Release helper path is an alias") }
        guard AutomationArtifactRegistry.digest(try Data(contentsOf: helper)) == receipt.helperSHA256 else {
            return XCTFail("Pinned release helper differs")
        }
        let command = AutomationOwnedCommand()
        let result = try await command.run(executable: helper, arguments: ["ownership-probe"],
            directory: URL(fileURLWithPath: "/private/tmp"), environment: [:], timeout: .seconds(5),
            ownershipGateNonce: UUID().uuidString.lowercased())
        let reply = try JSONDecoder().decode(Reply.self, from: result.stdout)
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.data.scope, "startup-ownership-only")
        XCTAssertFalse(reply.data.uiInteracted)
        XCTAssertEqual(reply.data.identity, result.ownedIdentity)
        XCTAssertTrue(result.startupAcknowledged)
        XCTAssertTrue(result.callbacksDrained)
        XCTAssertTrue(result.directChildReaped)
        XCTAssertTrue(result.pipesDrained)
        XCTAssertFalse(result.logsTruncated)
        XCTAssertEqual(AutomationArtifactRegistry.digest(try Data(contentsOf: helper)), receipt.helperSHA256)
        let stopped = await command.stopOwned()
        XCTAssertTrue(stopped)
    }
}
#endif
