#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

final class AutomationSourceSyntaxCompletionTests: XCTestCase {
    private func completeResult() -> AutomationOwnedCommand.Result {
        .init(exitStatus: 0, stdout: Data(), stderr: Data(), logsTruncated: false,
              ownedIdentity: .init(pid: 1, startIdentity: "fixture"),
              directChildReaped: true, pipesDrained: true, callbacksDrained: true)
    }
    func testVerifiedCompletionHasNoDiagnosticGaps() {
        XCTAssertEqual(AutomationSourceSyntaxDiscovery.completionGaps(completeResult()), [])
    }
    func testMissingIdentityIsDistinguishedFromUnreleasedResources() {
        var result = completeResult()
        result.ownedIdentity = nil
        XCTAssertEqual(AutomationSourceSyntaxDiscovery.completionGaps(result), ["process start identity not captured"])
    }
    func testEachIncompleteResourceProofIsReportedWithoutDroppingOtherGaps() {
        var result = completeResult()
        result.directChildReaped = false
        XCTAssertEqual(AutomationSourceSyntaxDiscovery.completionGaps(result), ["direct child not reaped"])
        result.pipesDrained = false
        result.callbacksDrained = false
        XCTAssertEqual(AutomationSourceSyntaxDiscovery.completionGaps(result),
                       ["direct child not reaped", "output pipes not drained", "callbacks not drained"])
    }
}
#endif
