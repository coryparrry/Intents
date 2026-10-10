#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

@MainActor final class AutomationSecretConsentViewTests: XCTestCase {
    private typealias View = AutomationSecretConsentView
    private let allStates: [AutomationSecretConsentModel.State] = [.idle, .verifying, .ready, .authorizing, .approved, .cancelled, .failed]
    private var nonReadyStates: [AutomationSecretConsentModel.State] { allStates.filter { $0 != .ready } }

    func testCredentialInputOnlyAcceptsTextWhileReadyAndOpen() {
        XCTAssertTrue(View.acceptsInput(state: .ready, closing: false))
        XCTAssertFalse(View.acceptsInput(state: .ready, closing: true))
        for state in nonReadyStates {
            XCTAssertFalse(View.acceptsInput(state: state, closing: false), "\(state)")
            XCTAssertFalse(View.acceptsInput(state: state, closing: true), "\(state)")
        }
    }

    func testAllowOneFillRequiresReadyOpenNonEmptyBoundedSecret() {
        XCTAssertTrue(View.canConfirm(state: .ready, closing: false, secret: "x"))
        XCTAssertFalse(View.canConfirm(state: .ready, closing: false, secret: ""))
        XCTAssertFalse(View.canConfirm(state: .ready, closing: true, secret: "x"))
        for state in nonReadyStates {
            XCTAssertFalse(View.canConfirm(state: state, closing: false, secret: "x"), "\(state)")
        }
    }

    func testAllowOneFillBoundaryCountsUTF16Units() {
        XCTAssertEqual(View.maximumSecretUTF16Count, 32768)
        let atLimit = String(repeating: "a", count: 32768)
        let overLimit = String(repeating: "a", count: 32769)
        XCTAssertTrue(View.canConfirm(state: .ready, closing: false, secret: atLimit))
        XCTAssertFalse(View.canConfirm(state: .ready, closing: false, secret: overLimit))
        // Each emoji is one Character but two UTF-16 units.
        let surrogatesAtLimit = String(repeating: "🔑", count: 16384)
        let surrogatesOverLimit = surrogatesAtLimit + "a"
        XCTAssertEqual(surrogatesAtLimit.count, 16384)
        XCTAssertTrue(View.canConfirm(state: .ready, closing: false, secret: surrogatesAtLimit))
        XCTAssertFalse(View.canConfirm(state: .ready, closing: false, secret: surrogatesOverLimit))
    }

    func testSecretIsClearedOnEveryTransitionAwayFromReady() {
        XCTAssertTrue(View.retainsSecret(state: .ready))
        for state in nonReadyStates { XCTAssertFalse(View.retainsSecret(state: state), "\(state)") }
    }

    func testProgressIsShownOnlyWhileCheckingTheSink() {
        for state in allStates {
            XCTAssertEqual(View.showsProgress(state: state), state == .verifying || state == .authorizing, "\(state)")
        }
    }

    func testConfirmedRequestIsDeliveredOnlyWhenApprovedAndStillOpen() {
        XCTAssertTrue(View.delivers(closing: false, state: .approved))
        XCTAssertFalse(View.delivers(closing: true, state: .approved))
        for state in allStates where state != .approved {
            XCTAssertFalse(View.delivers(closing: false, state: state), "\(state)")
        }
    }

    func testDisappearingWithoutDeliveryCancelsTheModel() {
        XCTAssertTrue(View.cancelsOnDisappear(delivered: false))
        XCTAssertFalse(View.cancelsOnDisappear(delivered: true))
    }

    func testEffectNoticeDistinguishesExternalWritesFromDisposableFixtures() {
        XCTAssertEqual(View.effectNotice(for: [.navigate, .externalWrite]), "This may change data in the selected app.")
        XCTAssertEqual(View.effectNotice(for: [.navigate, .fixtureWrite, .externalWrite]), "This may change data in the selected app.")
        XCTAssertEqual(View.effectNotice(for: [.navigate, .fixtureWrite]), "This may change the disposable test fixture.")
    }
}
#endif
