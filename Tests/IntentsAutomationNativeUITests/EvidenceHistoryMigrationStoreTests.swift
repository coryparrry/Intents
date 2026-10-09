#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

@MainActor final class EvidenceHistoryMigrationStoreTests: XCTestCase {
    private func store(_ importer: HistoryImporter) throws -> AppAutomationStore {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("native-history-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return AppAutomationStore(supportDirectory: root.appendingPathComponent("support"), savedCasesReader: { [] },
            evidenceImporter: { plan, report, _, _ in try await importer.importEvidence(plan, report) })
    }
    private func saveCase(_ model: AppAutomationStore, id: String, attempts: [String]) async throws -> (AutomationFrozenCase, [AutomationAttemptReport]) {
        let cases = try AutomationCaseStore(root: model.support.appendingPathComponent("Cases"))
        let plan = AutomationCase(id: id, app: .init(logicalID: "synthetic", bundleID: "example.Fixture", platform: "ios"),
            target: .init(id: "fixture", kind: .simulator), environmentID: "synthetic",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "Echo"))
        let frozen = try await cases.freeze(plan)
        var reports: [AutomationAttemptReport] = []
        for attemptID in attempts {
            let report = historyReport(plan: plan, attemptID: attemptID)
            try await cases.saveAttempt(report, for: frozen); reports.append(report)
        }
        return (frozen, reports)
    }
    func testMissingCaseHistoryCompletesWithoutImportingAndLaterCallsStayIdle() async throws {
        let importer = HistoryImporter()
        let model = try store(importer)
        await model.migrateEvidenceHistory()
        XCTAssertEqual(model.evidenceImportRevision, 0); XCTAssertNil(model.evidenceImportMessage)
        let (frozen, _) = try await saveCase(model, id: "later", attempts: ["recorded"])
        await importer.register(frozen)
        await model.migrateEvidenceHistory()
        let calls = await importer.calls
        XCTAssertEqual(calls, 0); XCTAssertEqual(model.evidenceImportRevision, 0); XCTAssertNil(model.evidenceImportMessage)
    }
    func testSavedAttemptsAreEachImportedOnceAndAnnouncedOnce() async throws {
        let importer = HistoryImporter()
        let model = try store(importer)
        let (first, firstReports) = try await saveCase(model, id: "alpha", attempts: ["recorded-a", "recorded-b"])
        let (second, secondReports) = try await saveCase(model, id: "beta", attempts: ["recorded-c"])
        await importer.register(first); await importer.register(second)
        await model.migrateEvidenceHistory()
        let imported = await importer.imported
        XCTAssertEqual(imported.map(\.frozen), [first, first, second])
        XCTAssertEqual(imported.map(\.report), firstReports + secondReports)
        XCTAssertEqual(model.evidenceImportRevision, 1); XCTAssertNil(model.evidenceImportMessage)
        await model.migrateEvidenceHistory()
        let calls = await importer.calls
        XCTAssertEqual(calls, 3); XCTAssertEqual(model.evidenceImportRevision, 1)
    }
    func testMismatchedImportedReportLeavesHistoryPendingUntilAVerifiedRetry() async throws {
        let importer = HistoryImporter(failure: .mismatchedReport)
        let model = try store(importer)
        let (frozen, reports) = try await saveCase(model, id: "mismatch", attempts: ["recorded"])
        await importer.register(frozen)
        await model.migrateEvidenceHistory()
        XCTAssertEqual(model.evidenceImportRevision, 0)
        XCTAssertEqual(model.evidenceImportMessage, "Existing attempts remain saved; native history import is incomplete: The selected source or prepared product changed. Prepare a fresh copy.")
        await importer.succeed()
        await model.migrateEvidenceHistory()
        let imported = await importer.imported
        XCTAssertEqual(imported.map(\.report), reports); XCTAssertEqual(model.evidenceImportRevision, 1)
    }
    func testMismatchedImportedCaseIsRejected() async throws {
        let importer = HistoryImporter(failure: .mismatchedCase)
        let model = try store(importer)
        let (frozen, _) = try await saveCase(model, id: "mismatch-case", attempts: ["recorded"])
        await importer.register(frozen)
        await model.migrateEvidenceHistory()
        XCTAssertEqual(model.evidenceImportRevision, 0)
        XCTAssertEqual(model.evidenceImportMessage, "Existing attempts remain saved; native history import is incomplete: The selected source or prepared product changed. Prepare a fresh copy.")
    }
    func testThrowingImporterLeavesHistoryPendingUntilARetrySucceeds() async throws {
        let importer = HistoryImporter(failure: .throwing)
        let model = try store(importer)
        let (frozen, reports) = try await saveCase(model, id: "throws", attempts: ["recorded-a", "recorded-b"])
        await importer.register(frozen)
        await model.migrateEvidenceHistory()
        let failedCalls = await importer.calls
        XCTAssertEqual(failedCalls, 1); XCTAssertEqual(model.evidenceImportRevision, 0)
        let message = try XCTUnwrap(model.evidenceImportMessage)
        XCTAssertTrue(message.hasPrefix("Existing attempts remain saved; native history import is incomplete: "), message)
        await importer.succeed()
        await model.migrateEvidenceHistory()
        let imported = await importer.imported
        XCTAssertEqual(imported.map(\.report), reports); XCTAssertEqual(model.evidenceImportRevision, 1)
    }
    func testConcurrentMigrationDoesNotReenterWhileAnImportIsHeld() async throws {
        let importer = HistoryImporter(holdFirst: true)
        let model = try store(importer)
        let (frozen, reports) = try await saveCase(model, id: "held", attempts: ["recorded"])
        await importer.register(frozen)
        let migration = Task { await model.migrateEvidenceHistory() }
        let held = await importer.waitUntilHeld()
        XCTAssertTrue(held, "Migration never reached the importer")
        guard held else { migration.cancel(); return }
        await model.migrateEvidenceHistory()
        let heldCalls = await importer.calls
        XCTAssertEqual(heldCalls, 1); XCTAssertEqual(model.evidenceImportRevision, 0)
        await importer.release(); await migration.value
        let imported = await importer.imported
        XCTAssertEqual(imported.map(\.report), reports); XCTAssertEqual(model.evidenceImportRevision, 1)
    }
    func testClosedStoreDoesNotMigrate() async throws {
        let importer = HistoryImporter()
        let model = try store(importer)
        let (frozen, _) = try await saveCase(model, id: "closed", attempts: ["recorded"])
        await importer.register(frozen)
        model.close()
        await model.migrateEvidenceHistory()
        let calls = await importer.calls
        XCTAssertEqual(calls, 0); XCTAssertEqual(model.evidenceImportRevision, 0); XCTAssertNil(model.evidenceImportMessage)
    }
}
// Synthetic recorded facts only; no app is executed.
private func historyReport(plan: AutomationCase, attemptID: String) -> AutomationAttemptReport {
    let result = AutomationAssessment.assess(plan: plan, attemptID: attemptID, subjectDispatched: false, subjectCompleted: false, observations: [], termination: .unresolved)
    return AutomationAttemptReport(attemptID: attemptID, result: result, receipts: [], resourcesReleased: true)
}
private enum HistoryImportError: Error { case failed }
private actor HistoryImporter {
    enum Failure { case mismatchedReport, mismatchedCase, throwing }
    private var failure: Failure?
    private var holdFirst: Bool
    private var frozenCases: [AutomationFrozenCase] = []
    private(set) var calls = 0
    private(set) var imported: [AutomationNativeEvidenceDocument] = []
    private var held = false
    private var pending: CheckedContinuation<Void, Never>?
    init(failure: Failure? = nil, holdFirst: Bool = false) { self.failure = failure; self.holdFirst = holdFirst }
    func register(_ frozen: AutomationFrozenCase) { frozenCases.append(frozen) }
    func succeed() { failure = nil }
    func waitUntilHeld() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !held, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return held
    }
    func release() { pending?.resume(); pending = nil }
    func importEvidence(_ plan: AutomationCase, _ report: AutomationAttemptReport) async throws -> AutomationNativeEvidenceDocument {
        calls += 1
        if holdFirst {
            holdFirst = false; held = true
            await withCheckedContinuation { pending = $0 }
        }
        guard let frozen = frozenCases.first(where: { $0.plan == plan }) else { throw HistoryImportError.failed }
        switch failure {
        case .throwing: throw HistoryImportError.failed
        case .mismatchedReport:
            return try AutomationNativeEvidenceDocument(frozen: frozen, report: historyReport(plan: plan, attemptID: report.attemptID + "-other"), artifacts: [])
        case .mismatchedCase:
            var other = plan; other.environmentID = "other-environment"
            return try AutomationNativeEvidenceDocument(frozen: AutomationFrozenCase(plan: other), report: historyReport(plan: other, attemptID: report.attemptID), artifacts: [])
        case nil:
            let document = try AutomationNativeEvidenceDocument(frozen: frozen, report: report, artifacts: [])
            imported.append(document); return document
        }
    }
}
#endif
