#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

final class AutomationXCUITestFailureDiagnosticTests: XCTestCase {
    private struct DiagnosticFailure: Error, CustomStringConvertible {
        let description: String
    }

    func testPreflightErrorIsRetainedWithoutInnerXCTestArtifactsAndRedactsCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let artifacts = try AutomationArtifactRegistry(root: root)
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "xcuitest", leaseGeneration: 1)
        let failure = AutomationContractError.missingEvidence("Private Mac app registration resolves to a different or missing private copy")
        let artifact = try await AutomationXCUITestCampaign.retainPreflightFailure(failure, artifacts: artifacts, scope: scope)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(artifact.relativePath))) as? [String: String])
        XCTAssertEqual(Set(fields.keys), ["stage", "errorType", "message"])
        XCTAssertEqual(fields["stage"], "xcuitest-execution")
        XCTAssertTrue(try XCTUnwrap(fields["message"]).contains("Private Mac app registration resolves"))
        XCTAssertTrue(artifact.relativePath.hasPrefix("xcuitest-preflight-failure-"))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("xcuitest-log-") })

        let credentials = DiagnosticFailure(description: "Authorization: Bearer fixture-auth\nSIGNING_PASSWORD=fixture-password\nopaque sk-proj-fixture123\nTest session failed to start")
        let redacted = try await AutomationXCUITestCampaign.retainPreflightFailure(credentials, artifacts: artifacts, scope: scope)
        let text = try String(contentsOf: root.appendingPathComponent(redacted.relativePath), encoding: .utf8)
        for withheld in ["fixture-auth", "fixture-password", "sk-proj-fixture123"] { XCTAssertFalse(text.contains(withheld)) }
        XCTAssertTrue(text.contains("Test session failed to start"))
        XCTAssertLessThan(redacted.byteCount, 16_384)
    }
}
#endif
