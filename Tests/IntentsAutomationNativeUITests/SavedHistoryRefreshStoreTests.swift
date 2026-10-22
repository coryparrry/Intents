#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore
@testable import IntentsAutomationNativeUI

@MainActor final class SavedHistoryRefreshStoreTests: XCTestCase {
    func testOlderRefreshCannotReplaceNewerCaseVersionsOrNotices() async throws {
        let original = AutomationCase(id: "history", app: .init(logicalID: "fixture", bundleID: "example.Fixture", platform: "ios"),
            target: .init(id: "fixture", kind: .simulator), environmentID: "fixture",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "Read"))
        let older = try AutomationFrozenCase(plan: original)
        var revised = original
        revised.revision += 1
        let newer = try AutomationFrozenCase(plan: revised)
        for failOlder in [false, true] {
            let root = URL(fileURLWithPath: "/private/tmp/history-refresh-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let reader = SavedHistoryRefreshReader(older: older, newer: newer, failOlder: failOlder)
            let model = AppAutomationStore(supportDirectory: root, savedCasesReader: { try await reader.read() })
            await model.ownershipRecoveryTask?.value
            let oldRefresh = Task { await model.refreshSavedCases() }
            await reader.waitForFirstRead()
            await model.refreshSavedCases()
            XCTAssertEqual(model.savedCases, [newer])
            XCTAssertNil(model.savedHistoryNotice)
            await reader.releaseFirstRead()
            await oldRefresh.value
            XCTAssertEqual(model.savedCases, [newer], "Older refresh replaced the current case version; failure=\(failOlder)")
            XCTAssertNil(model.savedHistoryNotice, "Older refresh replaced the current history notice; failure=\(failOlder)")
            await model.closeAndWait()
        }
    }
}

private actor SavedHistoryRefreshReader {
    let older: AutomationFrozenCase
    let newer: AutomationFrozenCase
    let failOlder: Bool
    private var first = true
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var suspended: CheckedContinuation<Void, Never>?

    init(older: AutomationFrozenCase, newer: AutomationFrozenCase, failOlder: Bool) {
        self.older = older; self.newer = newer; self.failOlder = failOlder
    }
    func read() async throws -> [AutomationFrozenCase] {
        guard first else { return [newer] }
        first = false
        entered = true
        entry?.resume(); entry = nil
        await withCheckedContinuation { suspended = $0 }
        if failOlder { throw AutomationContractError.invalidIdentity }
        return [older]
    }
    func waitForFirstRead() async {
        if entered { return }
        await withCheckedContinuation { entry = $0 }
    }
    func releaseFirstRead() { suspended?.resume(); suspended = nil }
}
#endif
