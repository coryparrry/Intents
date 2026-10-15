#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

@MainActor final class EvidenceHistoryStoreTests: XCTestCase {
    private actor Imports {
        var calls = 0
        let failFirst: Bool
        init(failFirst: Bool) { self.failFirst = failFirst }
        func record() throws {
            calls += 1
            if failFirst && calls == 1 { throw AutomationContractError.invalidIdentity }
        }
    }
    private func fixture(failFirst: Bool = false) async throws -> (AppAutomationStore, Imports, URL, AutomationFrozenCase) {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("history-store-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Automation")
        let cases = try AutomationCaseStore(root: support.appendingPathComponent("Cases"))
        let app = AppIdentity(logicalID: "app", bundleID: "example.App", platform: "ios", productDigest: String(repeating: "a", count: 64))
        let target = TargetIdentity(id: "sim", kind: .simulator)
        let plan = AutomationCase(id: "history", app: app, target: target, environmentID: "test",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "Action"),
            observations: [.init(id: "observe", kind: .ui, phase: .observe, operation: "Read")],
            requirements: [.init(observationID: "observe", expected: .bool(true), proof: .visibleState, justification: "Expected business state")])
        let frozen = try await cases.freeze(plan)
        let observation = AutomationObservation(id: "observe", app: app, target: target, environmentID: "test",
            attemptID: "attempt", stepID: "observe", route: .ui, proof: .visibleState, value: .bool(true))
        let receipts: [AutomationSegmentReceipt] = [
            .init(scope: .init(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: 1), app: app, target: target,
                  segmentID: "subject", route: .systemIntent, dispatched: true, completed: true),
            .init(scope: .init(runID: "run", attemptID: "attempt", segmentID: "observe", leaseGeneration: 2), app: app, target: target,
                  segmentID: "observe", route: .ui, dispatched: true, completed: true, observations: [observation])]
        let result = AutomationAssessment.assess(plan: plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: [observation])
        try await cases.saveAttempt(.init(attemptID: "attempt", result: result, receipts: receipts, resourcesReleased: true), for: frozen)
        var next = plan; next.revision += 1
        let unused = try await cases.freeze(next)
        let archive = try AutomationNativeEvidenceArchive(root: root.appendingPathComponent("IntentLab/Runs/AppAutomation"))
        let imports = Imports(failFirst: failFirst)
        let model = AppAutomationStore(supportDirectory: support, evidenceImporter: { plan, report, source, exposure in
            try await imports.record()
            let reader = try AutomationCaseStore(readOnlyRoot: source.appendingPathComponent("Cases"))
            let saved = try await reader.load(id: plan.id, revision: plan.revision, digest: AutomationFrozenCase.planDigest(plan))
            return try await archive.importAttempt(frozen: saved, report: report, sourceRoot: source, exposure: exposure)
        })
        return (model, imports, support, unused)
    }
    func testHistoryMigrationImportsRealSavedReportsAndLeavesUnexecutedCasesEmpty() async throws {
        let (model, imports, support, unused) = try await fixture()
        await model.migrateEvidenceHistory()
        XCTAssertNil(model.evidenceImportMessage)
        XCTAssertEqual(model.evidenceImportRevision, 1)
        let calls = await imports.calls
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("Cases/Attempts/" + unused.digest).path))
        XCTAssertNil(model.report)
        XCTAssertFalse(model.busy)
    }
    func testSuccessfulHistoryRetryClearsEarlierWarningWithoutReexecutingSubject() async throws {
        let (model, imports, _, _) = try await fixture(failFirst: true)
        await model.migrateEvidenceHistory()
        XCTAssertNotNil(model.evidenceImportMessage)
        XCTAssertEqual(model.evidenceImportRevision, 0)
        await model.migrateEvidenceHistory()
        XCTAssertNil(model.evidenceImportMessage)
        XCTAssertEqual(model.evidenceImportRevision, 1)
        let calls = await imports.calls
        XCTAssertEqual(calls, 2)
        XCTAssertNil(model.report)
        XCTAssertFalse(model.busy)
    }
}
#endif
