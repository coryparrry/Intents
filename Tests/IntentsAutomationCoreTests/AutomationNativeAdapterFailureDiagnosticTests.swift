#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationNativeAdapterFailureDiagnosticTests: XCTestCase {
    func testObservedAppleFrameworkSymbolLoadFailureExplainsTheAppPickerRecovery() {
        let stdout = Data("Failed to load the test bundle. Symbol not found: _$sMissing".utf8)
        let stderr = Data("Referenced from AppIntentsTesting.framework. Expected in AppIntentsServices.framework".utf8)
        let reason = AutomationInputAdapterProbeRunner.failureReason(stdout: stdout, stderr: stderr)
        XCTAssertTrue(reason.contains("required system symbol is missing"))
        XCTAssertTrue(reason.contains("Choose another installed Xcode"))
        XCTAssertTrue(reason.contains("prepare a fresh private copy"))
        XCTAssertTrue(reason.contains("no intent action was dispatched"))
    }
    func testUnrelatedFailuresDoNotClaimFrameworkIncompatibilityOrNoDispatch() {
        let facts = ["Failed to load the test bundle", "Symbol not found", "AppIntentsTesting.framework", "AppIntentsServices.framework"]
        for omitted in facts.indices {
            let text = facts.enumerated().filter { $0.offset != omitted }.map(\.element).joined(separator: "\n")
            XCTAssertEqual(AutomationInputAdapterProbeRunner.failureReason(stdout: Data(text.utf8), stderr: Data()), "Input adapter probe XCTest failed")
        }
        for text in ["XCTest assertion failed", "Symbol not found in Other.framework", "Input adapter readback mismatch", "User cancelled"] {
            XCTAssertEqual(AutomationInputAdapterProbeRunner.failureReason(stdout: Data(), stderr: Data(text.utf8)), "Input adapter probe XCTest failed")
        }
    }
}
#endif
