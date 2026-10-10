import XCTest
@testable import IntentsAutomationCore

final class AutomationSidecarReleaseDiagnosticsTests: XCTestCase {
    private let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "setup", leaseGeneration: 7)
    func testMissingAndNegativeProofComponentsRemainDistinct() throws {
        let unknown = AutomationSidecarReleaseDiagnostics(scope: scope, shutdown: nil, errorType: "Timeout", stopped: true,
            deviceReleased: true, subjectInspectionUnreleased: false, drained: true)
        XCTAssertFalse(unknown.shutdownReceived); XCTAssertNil(unknown.shutdownResourcesReleased)
        XCTAssertEqual(unknown.shutdownErrorType, "Timeout"); XCTAssertEqual(unknown.scope, scope)
        let denied = AutomationSidecarReleaseDiagnostics(scope: scope,
            shutdown: .object(["resourcesReleased": .bool(false), "cleanupReason": .string("sessionUnreleased")]),
            errorType: nil, stopped: true, deviceReleased: false, subjectInspectionUnreleased: true, drained: false)
        let decoded = try JSONDecoder().decode(AutomationSidecarReleaseDiagnostics.self, from: JSONEncoder().encode(denied))
        XCTAssertEqual(decoded, denied); XCTAssertEqual(decoded.shutdownResourcesReleased, false)
        XCTAssertEqual(decoded.shutdownCleanupReason, "sessionUnreleased"); XCTAssertFalse(decoded.commandsDrained)
    }
    func testUntrustedResponseValuesAndExtraFieldsAreNotDiagnosticContents() throws {
        let record = AutomationSidecarReleaseDiagnostics(scope: scope,
            shutdown: .object(["resourcesReleased": .string("private-proof"), "cleanupReason": .string("private-reason"), "error": .string("private-description")]),
            errorType: nil, stopped: false, deviceReleased: false, subjectInspectionUnreleased: false, drained: true)
        XCTAssertNil(record.shutdownResourcesReleased); XCTAssertEqual(record.shutdownCleanupReason, "unknown")
        let bytes = try JSONEncoder().encode(record)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("private-"))
    }
    func testRPCErrorCodeRetainsCaseWithoutRemoteText() throws {
        XCTAssertEqual(AutomationSidecarReleaseDiagnostics.errorCode(AutomationRPCError.dispatchedOutcomeUnknown), "dispatchedOutcomeUnknown")
        let code = AutomationSidecarReleaseDiagnostics.errorCode(AutomationRPCError.remote(code: -1, message: "private-message"))
        XCTAssertEqual(code, "remote")
        let record = AutomationSidecarReleaseDiagnostics(scope: scope, shutdown: nil, errorType: nil, errorCode: code,
            stopped: true, deviceReleased: true, subjectInspectionUnreleased: false, drained: true)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(record), as: UTF8.self).contains("private-message"))
        XCTAssertEqual(record.shutdownErrorCode, "remote")
    }
}
