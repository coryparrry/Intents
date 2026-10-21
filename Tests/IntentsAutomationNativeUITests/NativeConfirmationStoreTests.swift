#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

extension InstalledUIStoreTests {
    func testStaleRunConfirmationCannotInvalidateAReplacementRequest() async throws {
        let (model, root, _) = try await fixture()
        try selectPreparedSource(model: model, root: root)
        await model.ownershipRecoveryTask?.value
        let reviewed = try await model.prepareNativeConfirmation(.run)
        let replacementID = UUID()
        var replaced = false
        var replacementError: (any Error)?
        // Replace the request at the existing admission boundary, after the
        // confirmation captured its pending ID and before verification returns.
        model.executionCanStart = { [weak model] in
            guard let model else { return false }
            if !replaced {
                replaced = true
                do {
                    _ = try model.cancelCommand(id: reviewed.id)
                    _ = try model.requestCommand(id: replacementID, digest: reviewed.digest)
                } catch { replacementError = error }
            }
            return true
        }
        do {
            try await model.confirmNativeRequest(reviewed)
            XCTFail("The replaced request was confirmed")
        } catch {}
        XCTAssertTrue(replaced)
        XCTAssertNil(replacementError)
        XCTAssertEqual(try model.commandStatus(id: reviewed.id).state, "cancelled")
        XCTAssertEqual(model.pendingCommandStatus?.requestID, replacementID)
        XCTAssertEqual(try model.commandStatus(id: replacementID).state, "awaitingApproval")
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.task)
        model.executionCanStart = nil
        _ = try model.cancelCommand(id: replacementID)
        await model.closeAndWait()
    }

    func testVerifiedRemoteRequestAdmitsFreshIDBeforeAndAfterNativeHistoryFills() async throws {
        for nativeCount in [0, AutomationCommandHistory.retentionLimit] {
            let (model, root, _) = try await fixture()
            try selectPreparedSource(model: model, root: root)
            for _ in 0..<nativeCount {
                let review = try await model.prepareNativeConfirmation(.run)
                _ = try model.cancelCommand(id: review.id)
            }
            let preview = try await model.verifiedPreviewCommand()
            let id = UUID()
            let status = try await model.verifiedRequestCommand(id: id, digest: preview.digest)
            XCTAssertEqual(status.state, "awaitingApproval")
            XCTAssertEqual(model.pendingCommandStatus?.requestID, id)
            XCTAssertFalse(model.busy, "Queuing a remote request must not execute it")
            let repeated = try await model.verifiedRequestCommand(id: id, digest: preview.digest)
            XCTAssertEqual(repeated.requestID, status.requestID)
            XCTAssertEqual(repeated.digest, status.digest)
            XCTAssertEqual(repeated.state, status.state)
            _ = try model.cancelCommand(id: id)
            await model.closeAndWait()
        }
    }

    func testNativeConfirmationHistoryExpiresTerminalPayloadsWithoutExhaustingAdmission() async throws {
        let (model, root, _) = try await fixture()
        XCTAssertFalse(model.canRun, "An installed app without an associated host cannot run a workflow")
        try selectPreparedSource(model: model, root: root)
        XCTAssertTrue(model.canRun)
        var reviews: [AutomationNativeConfirmationReview] = []
        for index in 0..<65 {
            let review = try await model.prepareNativeConfirmation(.run)
            reviews.append(review)
            if index.isMultiple(of: 2) { _ = try model.cancelCommand(id: review.id) }
            else { model.preparationSelectionChanged() }
        }
        XCTAssertTrue(model.canRun)
        XCTAssertNil(model.pendingCommandStatus)
        let expired = try XCTUnwrap(reviews.first)
        XCTAssertThrowsError(try model.commandStatus(id: expired.id))
        XCTAssertThrowsError(try model.requestCommand(id: expired.id, digest: expired.digest))
        do {
            _ = try await model.requestReproductionCommand(id: expired.id, digest: expired.digest)
            XCTFail("Expired native request was adopted for reproduction")
        } catch { XCTAssertEqual(error as? AutomationContractError, .conflictingOperation) }
        do {
            _ = try await model.requestComparisonCommand(id: expired.id, digest: expired.digest)
            XCTFail("Expired native request was adopted for comparison")
        } catch { XCTAssertEqual(error as? AutomationContractError, .conflictingOperation) }
        XCTAssertNil(model.pendingCommandStatus)
        let latest = try XCTUnwrap(reviews.last)
        XCTAssertEqual(try model.commandStatus(id: latest.id).state, "cancelled")
        XCTAssertThrowsError(try model.requestCommand(id: latest.id, digest: latest.digest))
        let next = try await model.prepareNativeConfirmation(.run)
        XCTAssertEqual(model.pendingCommandStatus?.requestID, next.id)
        _ = try model.cancelCommand(id: next.id)
    }

    func testExternalIdempotentHistoryLimitDoesNotBlockNativeConfirmations() async throws {
        let (model, root, _) = try await fixture()
        XCTAssertFalse(model.canRun, "An installed app without an associated host cannot run a workflow")
        try selectPreparedSource(model: model, root: root)
        XCTAssertTrue(model.canRun)
        let preview = try model.previewCommand()
        var externalIDs: [UUID] = []
        for _ in 0..<50 {
            let id = UUID(); externalIDs.append(id)
            _ = try model.requestCommand(id: id, digest: preview.digest)
            let review = try await model.prepareNativeConfirmation(.run)
            XCTAssertEqual(review.id, id)
            _ = try model.cancelCommand(id: id)
        }
        XCTAssertThrowsError(try model.requestCommand(id: UUID(), digest: preview.digest))
        for _ in 0..<65 {
            let review = try await model.prepareNativeConfirmation(.run)
            _ = try model.cancelCommand(id: review.id)
        }
        for id in externalIDs {
            XCTAssertEqual(try model.commandStatus(id: id).state, "cancelled")
            XCTAssertEqual(try model.requestCommand(id: id, digest: preview.digest).state, "cancelled")
        }
        XCTAssertThrowsError(try model.requestCommand(id: externalIDs[0], digest: String(repeating: "f", count: 64)))
        XCTAssertThrowsError(try model.requestCommand(id: UUID(), digest: preview.digest))
        XCTAssertNil(model.pendingCommandStatus)
    }

    func testNativeHistoryPinsActiveRequestsEvenAfterTheirStatusBecomesTerminal() throws {
        var history = AutomationCommandHistory()
        var requests: [UUID: AutomationNativeCommandStatus] = [:]
        var ids: [UUID] = []
        for _ in 0..<50 {
            let id = history.nativeRequestID(requests: &requests, pending: nil, active: nil)
            ids.append(id)
            requests[id] = .init(requestID: id, digest: "digest", state: "cancelled")
            history.admitted(id)
        }
        let active = ids[0]
        requests[active]?.state = "completed"
        let next = history.nativeRequestID(requests: &requests, pending: nil, active: active)
        XCTAssertEqual(requests[active]?.state, "completed")
        XCTAssertNil(requests[ids[1]])
        XCTAssertFalse(history.canAdmit(ids[1], nativeConfirmation: false, requests: requests))
        requests[next] = .init(requestID: next, digest: "digest", state: "awaitingApproval")
        history.admitted(next)
        XCTAssertEqual(history.nativeRequestID(requests: &requests, pending: next, active: active), next)
        XCTAssertEqual(requests[next]?.state, "awaitingApproval")
        XCTAssertEqual(requests[active]?.state, "completed")
    }

    func testNativeRunConfirmationRejectsLateInventoryDestinationDriftWithoutFallback() async throws {
        let gate = NativeConfirmationGate(), calls = NativeConfirmationCalls()
        let replacement = AutomationSimulator(id: UUID().uuidString, name: "Replacement", runtime: "iOS", state: "Shutdown")
        let (model, _, _) = try await fixture(executor: { _, _, _, _, _, _ in
            await calls.mark(); throw AutomationContractError.invalidIdentity
        }, simulatorInventoryReader: { _, _ in await gate.hold(); return [replacement] })
        let original = model.simulatorID
        let inventory = Task { await model.refreshTargets() }; await gate.waitForEntry()
        let review = try await model.prepareNativeConfirmation(.run)
        XCTAssertTrue(review.message.contains(original))
        XCTAssertEqual(model.pendingCommandStatus?.requestID, review.id)
        await gate.release(); await inventory.value
        XCTAssertEqual(model.simulatorID, replacement.id); XCTAssertFalse(model.canRun)
        do { try await model.confirmNativeRequest(review); XCTFail("Changed destination approved") } catch {}
        let count = await calls.count; XCTAssertEqual(count, 0)
        XCTAssertFalse(model.busy); XCTAssertNil(model.report); XCTAssertNil(model.pendingCommandStatus)
        XCTAssertEqual(try model.commandStatus(id: review.id).state, "invalidated")
    }
    func testNativeRunCancellationAndInvalidatedRequestCannotFallBackToDirectExecution() async throws {
        let calls = NativeConfirmationCalls()
        let (model, _, _) = try await fixture(executor: { _, _, _, _, _, _ in
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
        let (model, root, _) = try await fixture(); let frozen = try await saveFailure(model: model, root: root)
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
        let (model, root, _) = try await fixture(); try selectPreparedSource(model: model, root: root)
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
        let (model, _, _) = try await fixture(executor: { _, _, _, _, _, _ in
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
