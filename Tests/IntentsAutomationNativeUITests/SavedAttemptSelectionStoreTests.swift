#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

extension InstalledUIStoreTests {
    private func addSavedAttempt(model: AppAutomationStore, frozen: AutomationFrozenCase, id: String, fails: Bool) async throws -> AutomationAttemptReport {
        let cases = try AutomationCaseStore(root: model.support.appendingPathComponent("Cases"))
        var approval = RunApproval(runID: id, app: frozen.plan.app, target: frozen.plan.target, environmentID: frozen.plan.environmentID,
            effects: [.observe, .navigate], maximumActions: 30, disposable: false)
        approval.approvedCaseDigest = frozen.digest
        let report = try await NativeSearchFactExecutor(fails: fails).execute(frozen: frozen, approval: approval, attemptID: id,
            budget: .init(limits: .firstCampaign))
        try await cases.saveAttempt(report, for: frozen)
        return report
    }
    func testMultipleSavedAttemptsRequireChoiceRegardlessOfLexicalOrInsertionOrder() async throws {
        let (model, root, _) = try fixture(); let frozen = try await saveFailure(model: model, root: root)
        _ = try await addSavedAttempt(model: model, frozen: frozen, id: "zzz-earlier-pass", fails: false)
        let failure = try await addSavedAttempt(model: model, frozen: frozen, id: "aaa-later-failure", fails: true)
        await model.showSavedCase(frozen)
        XCTAssertEqual(model.savedViewedAttempts.count, 3)
        XCTAssertNil(model.savedViewedReport); XCTAssertNil(model.canonicalSavedEvidence)
        XCTAssertFalse(model.canReproduceSavedFailure); XCTAssertFalse(model.canCheckFix)
        await model.selectSavedAttempt(id: failure.attemptID)
        XCTAssertEqual(model.savedViewedReport, failure)
        XCTAssertTrue(model.canReproduceSavedFailure)
        let preview = try await model.previewReproductionCommand()
        XCTAssertEqual(preview.originalAttemptID, "aaa-later-failure")
        await model.selectSavedAttempt(id: "zzz-earlier-pass")
        XCTAssertEqual(model.savedViewedReport?.result.summary, .passed)
        XCTAssertFalse(model.canReproduceSavedFailure)
        do { _ = try await model.previewReproductionCommand(); XCTFail("Pass became reproduction oracle") } catch {}
    }
    func testChangingSavedAttemptInvalidatesQueuedReproductionAndOldPreview() async throws {
        let (model, root, _) = try fixture(); let frozen = try await saveFailure(model: model, root: root)
        let preview = try await model.previewReproductionCommand(), id = UUID()
        _ = try await model.requestReproductionCommand(id: id, digest: preview.digest)
        let failure = try await addSavedAttempt(model: model, frozen: frozen, id: "other-failure", fails: true)
        await model.showSavedCase(frozen, attemptID: failure.attemptID)
        XCTAssertEqual(try model.commandStatus(id: id).state, "invalidated")
        XCTAssertNil(model.pendingCommandStatus)
        let changed = try await model.previewReproductionCommand()
        XCTAssertNotEqual(changed.digest, preview.digest); XCTAssertEqual(changed.originalAttemptID, failure.attemptID)
        do { _ = try await model.requestReproductionCommand(id: UUID(), digest: preview.digest); XCTFail("Old preview accepted") } catch {}
    }
    func testChangingSavedAttemptInvalidatesQueuedFixComparisonAndBindsNewOracle() async throws {
        let (model, root, _) = try fixture(); try selectPreparedSource(model: model, root: root)
        let frozen = try await saveFailure(model: model, root: root), baseline = try XCTUnwrap(model.prepared)
        model.prepared = try changedPreparedSource(baseline); model.catalog = model.prepared?.catalog; model.installApproved = true
        let preview = try await model.previewComparisonCommand(), id = UUID()
        _ = try await model.requestComparisonCommand(id: id, digest: preview.digest)
        let failure = try await addSavedAttempt(model: model, frozen: frozen, id: "other-failure", fails: true)
        await model.showSavedCase(frozen, attemptID: failure.attemptID)
        XCTAssertEqual(try model.commandStatus(id: id).state, "invalidated"); XCTAssertNil(model.pendingCommandStatus)
        let changed = try await model.previewComparisonCommand()
        XCTAssertEqual(changed.originalAttemptID, failure.attemptID); XCTAssertNotEqual(changed.digest, preview.digest)
        do { _ = try await model.requestComparisonCommand(id: UUID(), digest: preview.digest); XCTFail("Old comparison preview accepted") } catch {}
    }
    func testUnknownAttemptAndEmptyDraftCannotLeavePriorFailureSelected() async throws {
        let (model, root, _) = try fixture(); let frozen = try await saveFailure(model: model, root: root)
        await model.selectSavedAttempt(id: "not-present")
        XCTAssertNil(model.savedViewedReport); XCTAssertNil(model.savedViewedCase); XCTAssertTrue(model.savedViewedAttempts.isEmpty)
        XCTAssertFalse(model.canReproduceSavedFailure)
        await model.showSavedCase(frozen); XCTAssertEqual(model.savedViewedReport?.attemptID, "original")
        let cases = try AutomationCaseStore(root: model.support.appendingPathComponent("Cases"))
        var draft = frozen.plan; draft.revision += 1
        let empty = try await cases.freeze(draft)
        await model.showSavedCase(empty)
        XCTAssertEqual(model.savedViewedCase, empty); XCTAssertTrue(model.savedViewedAttempts.isEmpty)
        XCTAssertNil(model.savedViewedReport); XCTAssertNil(model.savedViewedDirectory); XCTAssertNil(model.canonicalSavedEvidence)
        XCTAssertFalse(model.savedAttemptLoading); XCTAssertFalse(model.canReproduceSavedFailure)
    }
    func testOlderLoadCannotOverwriteNewExplicitChoice() async throws {
        let (owner, root, _) = try fixture(); let frozen = try await saveFailure(model: owner, root: root)
        let original = try XCTUnwrap(owner.savedViewedReport)
        let other = try await addSavedAttempt(model: owner, frozen: frozen, id: "other-failure", fails: true)
        let gate = SavedAttemptReadGate()
        let model = AppAutomationStore(supportDirectory: owner.support, savedAttemptsReader: { _ in
            await gate.holdFirstRead(); return [original, other]
        })
        let old = Task { await model.showSavedCase(frozen, attemptID: original.attemptID) }
        await gate.waitForEntry()
        await model.showSavedCase(frozen, attemptID: other.attemptID)
        XCTAssertEqual(model.savedViewedReport, other)
        await gate.release(); await old.value
        XCTAssertEqual(model.savedViewedReport, other); XCTAssertFalse(model.savedAttemptLoading)
    }
    func testCancelledOrClosedLoadCannotPublishAfterReaderIgnoresCancellation() async throws {
        for close in [false, true] {
            let (owner, root, _) = try fixture(); let frozen = try await saveFailure(model: owner, root: root)
            let original = try XCTUnwrap(owner.savedViewedReport), gate = SavedAttemptReadGate()
            let model = AppAutomationStore(supportDirectory: owner.support, savedAttemptsReader: { _ in
                await gate.holdFirstRead(); return [original]
            })
            let task = Task { await model.showSavedCase(frozen) }; await gate.waitForEntry()
            if close { model.close() } else { task.cancel() }
            await gate.release(); await task.value
            XCTAssertNil(model.savedViewedCase); XCTAssertNil(model.savedViewedReport)
            XCTAssertFalse(model.savedAttemptLoading); XCTAssertTrue(model.savedViewedAttempts.isEmpty)
        }
    }
    func testDuplicateAttemptReaderResultCannotBecomeAnOracle() async throws {
        let (owner, root, _) = try fixture(); let frozen = try await saveFailure(model: owner, root: root)
        let original = try XCTUnwrap(owner.savedViewedReport)
        let model = AppAutomationStore(supportDirectory: owner.support, savedAttemptsReader: { _ in [original, original] })
        await model.showSavedCase(frozen, attemptID: original.attemptID)
        XCTAssertNil(model.savedViewedReport); XCTAssertNil(model.savedViewedCase)
        XCTAssertFalse(model.savedAttemptLoading); XCTAssertTrue(model.savedViewedAttempts.isEmpty)
    }
    func testCancellationDuringHeldEvidenceImportClearsSelectedReportAndEvidence() async throws {
        let (owner, root, _) = try fixture(); let frozen = try await saveFailure(model: owner, root: root)
        let gate = SavedAttemptReadGate()
        let model = AppAutomationStore(supportDirectory: owner.support, evidenceImporter: { plan, report, _, _ in
            await gate.holdFirstRead()
            return try .init(frozen: AutomationFrozenCase(plan: plan), report: report, artifacts: [])
        })
        let task = Task { await model.showSavedCase(frozen) }; await gate.waitForEntry()
        XCTAssertNotNil(model.savedViewedReport)
        task.cancel(); await gate.release(); await task.value
        XCTAssertNil(model.savedViewedCase); XCTAssertNil(model.savedViewedReport)
        XCTAssertNil(model.canonicalSavedEvidence); XCTAssertNil(model.canonicalSavedPresentation)
        XCTAssertFalse(model.savedAttemptLoading); XCTAssertTrue(model.savedViewedAttempts.isEmpty)
    }
}
private actor SavedAttemptReadGate {
    private var first = true
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var suspended: CheckedContinuation<Void, Never>?
    func holdFirstRead() async {
        guard first else { return }; first = false; entered = true
        entry?.resume(); entry = nil
        await withCheckedContinuation { suspended = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entry = $0 }
    }
    func release() { suspended?.resume(); suspended = nil }
}
#endif
