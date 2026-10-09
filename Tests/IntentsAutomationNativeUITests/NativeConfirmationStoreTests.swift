#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

extension InstalledUIStoreTests {
    func testNativeRunConfirmationRejectsLateInventoryDestinationDriftWithoutFallback() async throws {
        let gate = NativeConfirmationGate(), calls = NativeConfirmationCalls()
        let replacement = AutomationSimulator(id: UUID().uuidString, name: "Replacement", runtime: "iOS", state: "Shutdown")
        let (model, _, _) = try fixture(executor: { _, _, _, _, _, _ in
            await calls.mark(); throw AutomationContractError.invalidIdentity
        }, simulatorInventoryReader: { _, _ in await gate.hold(); return [replacement] })
        let original = model.simulatorID
        let inventory = Task { await model.refreshTargets() }; await gate.waitForEntry()
        let review = try await model.prepareNativeConfirmation(.run)
        XCTAssertTrue(review.message.contains(original))
        XCTAssertEqual(model.pendingCommandStatus?.requestID, review.id)
        await gate.release(); await inventory.value
        XCTAssertEqual(model.simulatorID, replacement.id); XCTAssertTrue(model.canRun)
        do { try await model.confirmNativeRequest(review); XCTFail("Changed destination approved") } catch {}
        let count = await calls.count; XCTAssertEqual(count, 0)
        XCTAssertFalse(model.busy); XCTAssertNil(model.report); XCTAssertNil(model.pendingCommandStatus)
        XCTAssertEqual(try model.commandStatus(id: review.id).state, "invalidated")
    }
    func testNativeRunCancellationAndInvalidatedRequestCannotFallBackToDirectExecution() async throws {
        let calls = NativeConfirmationCalls()
        let (model, _, _) = try fixture(executor: { _, _, _, _, _, _ in
            await calls.mark(); throw AutomationContractError.invalidIdentity
        })
        let cancelled = try await model.prepareNativeConfirmation(.run)
        _ = try model.cancelCommand(id: cancelled.id)
        do { try await model.confirmNativeRequest(cancelled); XCTFail("Cancelled request approved") } catch {}
        let stale = try await model.prepareNativeConfirmation(.run)
        model.preparationSelectionChanged()
        XCTAssertTrue(model.canRun)
        do { try await model.confirmNativeRequest(stale); XCTFail("Invalidated request fell back") } catch {}
        let count = await calls.count; XCTAssertEqual(count, 0); XCTAssertFalse(model.busy)
    }
    func testNativeReproductionConfirmationNamesAndRetainsExactAttempt() async throws {
        let (model, root, _) = try fixture(); let frozen = try await saveFailure(model: model, root: root)
        let review = try await model.prepareNativeConfirmation(.reproduction)
        XCTAssertTrue(review.message.contains("Saved attempt: original"))
        XCTAssertEqual(model.pendingCommandStatus?.originalAttemptID, "original")
        let changedKind = AutomationNativeConfirmationReview.init(id: review.id, digest: review.digest, kind: .run, message: review.message)
        do { try await model.confirmNativeRequest(changedKind); XCTFail("Reproduction approved as normal run") } catch {}
        let cases = try AutomationCaseStore(root: model.support.appendingPathComponent("Cases"))
        var approval = RunApproval(runID: "other", app: frozen.plan.app, target: frozen.plan.target, environmentID: frozen.plan.environmentID,
            effects: [.observe, .navigate], maximumActions: 30, disposable: false)
        approval.approvedCaseDigest = frozen.digest
        let other = try await NativeSearchFactExecutor(fails: true).execute(frozen: frozen, approval: approval, attemptID: "other", budget: .init(limits: .firstCampaign))
        try await cases.saveAttempt(other, for: frozen)
        await model.showSavedCase(frozen, attemptID: "other")
        do { try await model.confirmNativeRequest(review); XCTFail("Changed original attempt approved") } catch {}
        XCTAssertFalse(model.busy); XCTAssertNil(model.reproductionReport)
        XCTAssertEqual(try model.commandStatus(id: review.id).state, "invalidated")
    }
    func testNativeComparisonConfirmationFreezesBothBuildsAndRejectsChangedSelection() async throws {
        let (model, root, _) = try fixture(); try selectPreparedSource(model: model, root: root)
        _ = try await saveFailure(model: model, root: root); let before = try XCTUnwrap(model.prepared)
        model.prepared = try changedPreparedSource(before); model.catalog = model.prepared?.catalog; model.installApproved = true
        let review = try await model.prepareNativeConfirmation(.comparison)
        XCTAssertTrue(review.message.contains("Original build: " + String(try XCTUnwrap(before.host.app.productDigest).prefix(12))))
        XCTAssertTrue(review.message.contains("Fixed build: " + String(try XCTUnwrap(model.prepared?.host.app.productDigest).prefix(12))))
        model.configuration = "Release"; model.preparationSelectionChanged()
        do { try await model.confirmNativeRequest(review); XCTFail("Changed build selection approved") } catch {}
        XCTAssertFalse(model.busy); XCTAssertNil(model.comparisonReport)
        XCTAssertEqual(try model.commandStatus(id: review.id).state, "invalidated")
    }
    func testNativeConfirmationReusesMatchingRemoteRequestAndRunsOnlyOnce() async throws {
        let calls = NativeConfirmationCalls()
        let (model, _, _) = try fixture(executor: { _, _, _, _, _, _ in
            await calls.mark(); throw AutomationContractError.invalidIdentity
        })
        let preview = try model.previewCommand(), id = UUID()
        _ = try model.requestCommand(id: id, digest: preview.digest)
        let review = try await model.prepareNativeConfirmation(.run)
        XCTAssertEqual(review.id, id); XCTAssertEqual(review.digest, preview.digest)
        try await model.confirmNativeRequest(review)
        await calls.waitForCall()
        do { try await model.confirmNativeRequest(review); XCTFail("Duplicate confirmation executed") } catch {}
        await model.closeAndWait()
        let count = await calls.count; XCTAssertEqual(count, 1)
    }
}
private actor NativeConfirmationCalls {
    var count = 0
    private var waiter: CheckedContinuation<Void, Never>?
    func mark() { count += 1; waiter?.resume(); waiter = nil }
    func waitForCall() async { if count > 0 { return }; await withCheckedContinuation { waiter = $0 } }
}
private actor NativeConfirmationGate {
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var suspended: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; entry?.resume(); entry = nil; await withCheckedContinuation { suspended = $0 } }
    func waitForEntry() async { if entered { return }; await withCheckedContinuation { entry = $0 } }
    func release() { suspended?.resume(); suspended = nil }
}
#endif
