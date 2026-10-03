import Foundation
import IntentLabContracts
@testable import IntentLabCoreTesting
import XCTest

final class IntentLabReadinessTests: XCTestCase {
    func testDirectReadinessRequiresDeclaredControlAndPositiveTypedReply() {
        XCTAssertEqual(
            IntentLabReadinessStatusPolicy.direct(
                controlDeclared: false,
                executorAvailable: true,
                observations: [IntentLabReadinessObservation.ready: .boolean(true)]
            ),
            .setupRequired
        )
        XCTAssertEqual(
            IntentLabReadinessStatusPolicy.direct(
                controlDeclared: true,
                executorAvailable: false,
                observations: nil
            ),
            .notYetVerified
        )
        XCTAssertEqual(
            IntentLabReadinessStatusPolicy.direct(
                controlDeclared: true,
                executorAvailable: true,
                observations: [IntentLabReadinessObservation.ready: .boolean(false)]
            ),
            .environmentBlocked
        )
        XCTAssertEqual(
            IntentLabReadinessStatusPolicy.direct(
                controlDeclared: true,
                executorAvailable: true,
                observations: [IntentLabReadinessObservation.ready: .string("true")]
            ),
            .environmentBlocked
        )
        XCTAssertEqual(
            IntentLabReadinessStatusPolicy.direct(
                controlDeclared: true,
                executorAvailable: true,
                observations: [:]
            ),
            .environmentBlocked
        )
        XCTAssertEqual(
            IntentLabReadinessStatusPolicy.direct(
                controlDeclared: true,
                executorAvailable: true,
                observations: [IntentLabReadinessObservation.ready: .boolean(true)]
            ),
            .ready
        )
    }

    func testReadySiriDriverDoesNotClaimSiriSettingsWereVerified() {
        XCTAssertEqual(
            IntentLabReadinessStatusPolicy.siri(
                readinessOperationDeclared: true,
                appLaunched: true,
                observationCompleted: true
            ),
            .ready
        )
        XCTAssertEqual(
            IntentLabReadinessStatusPolicy.siri(
                readinessOperationDeclared: false,
                appLaunched: true,
                observationCompleted: true
            ),
            .setupRequired
        )
        XCTAssertEqual(
            IntentLabReadinessStatusPolicy.siri(
                readinessOperationDeclared: true,
                appLaunched: false,
                observationCompleted: false
            ),
            .environmentBlocked
        )
    }

    func testFeatureReadinessUsesSharedSupportAndObserverPrerequisites() {
        XCTAssertEqual(
            IntentLabReadinessStatusPolicy.feature(
                directStatus: .environmentBlocked,
                featureControlDeclared: true,
                capabilitiesDeclared: true,
                capabilitiesSupported: true,
                observersReady: true
            ),
            .environmentBlocked
        )
        XCTAssertEqual(
            IntentLabReadinessStatusPolicy.feature(
                directStatus: .ready,
                featureControlDeclared: false,
                capabilitiesDeclared: true,
                capabilitiesSupported: true,
                observersReady: true
            ),
            .setupRequired
        )
        XCTAssertEqual(
            IntentLabReadinessStatusPolicy.feature(
                directStatus: .ready,
                featureControlDeclared: true,
                capabilitiesDeclared: true,
                capabilitiesSupported: true,
                observersReady: false
            ),
            .environmentBlocked
        )
        XCTAssertEqual(
            IntentLabReadinessStatusPolicy.feature(
                directStatus: .ready,
                featureControlDeclared: true,
                capabilitiesDeclared: true,
                capabilitiesSupported: true,
                observersReady: true
            ),
            .ready
        )
        XCTAssertEqual(
            IntentLabReadinessStatusPolicy.feature(
                directStatus: .notYetVerified,
                featureControlDeclared: true,
                capabilitiesDeclared: true,
                capabilitiesSupported: false,
                observersReady: true
            ),
            .notYetVerified
        )
    }

    func testReceiptRoundTripsTypedRouteEvidenceAndTestIdentity() throws {
        let createdAt = ISO8601DateFormatter().date(from: "2026-09-29T12:34:56Z")!
        let route = IntentLabReadinessRoute(
            status: .ready,
            operationID: "intentLabReadiness",
            supportType: "appIntentsTestingReadiness",
            context: "intentlab-readiness-intentIntegration-7BF2",
            observations: ["readiness.ready": .boolean(true)]
        )
        let receipt = IntentLabReadinessReceipt(
            schemaVersion: 1,
            testName: "testIntentLabReadiness",
            testIdentifier: "Example.IntentLabScenarioTests/testIntentLabReadiness",
            testMethodStarted: true,
            createdAt: createdAt,
            targetBundleIdentifier: "com.example.IntentLabFixture",
            testBundleIdentifier: "com.example.IntentLabFixture.integration-tests",
            integration: IntentLabIntegrationIdentity(id: "fixture", version: "1", digest: String(repeating: "a", count: 64)),
            routes: [
                IntentLabReadinessRouteKey.intentIntegration: route,
                IntentLabReadinessRouteKey.siri: IntentLabReadinessRoute(status: .notYetVerified),
                IntentLabReadinessRouteKey.appFeature: IntentLabReadinessRoute(status: .notYetVerified)
            ]
        )

        let encoded = try JSONEncoder.intentLab.encode(receipt)
        let decoded = try JSONDecoder.intentLab.decode(IntentLabReadinessReceipt.self, from: encoded)

        XCTAssertEqual(decoded.testName, "testIntentLabReadiness")
        XCTAssertTrue(decoded.testMethodStarted)
        XCTAssertEqual(decoded.testIdentifier, receipt.testIdentifier)
        XCTAssertEqual(decoded.createdAt, createdAt)
        XCTAssertEqual(decoded.routes[IntentLabReadinessRouteKey.intentIntegration]?.status, .ready)
        XCTAssertEqual(
            decoded.routes[IntentLabReadinessRouteKey.intentIntegration]?.observations?[IntentLabReadinessObservation.ready],
            .boolean(true)
        )
    }
}
