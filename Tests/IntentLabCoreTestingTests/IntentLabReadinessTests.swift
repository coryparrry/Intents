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

}
