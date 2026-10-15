#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

extension InstalledUIStoreTests {
    func testReturnedRunStatusUsesEvidenceAfterCancellationRequest() async throws {
        for summary in [AttemptResult.Summary.cancelled, .infrastructureFailed, .passed] {
            let gate = ReturnedCancellationGate()
            let (model, _, _) = try await fixture(executor: { _, plan, approval, _, attemptID, _ in
                await gate.hold()
                if summary == .passed {
                    return try await NativeSearchFactExecutor().execute(frozen: try AutomationFrozenCase(plan: plan), approval: approval,
                        attemptID: attemptID, budget: .init(limits: .firstCampaign))
                }
                return .init(attemptID: attemptID, result: AutomationAssessment.assess(plan: plan, attemptID: attemptID,
                    subjectDispatched: false, subjectCompleted: false, observations: [], termination: summary),
                    receipts: [], resourcesReleased: false)
            })
            model.uiExpectedText = "Complete"
            let review = try await model.prepareNativeConfirmation(.run)
            try await model.confirmNativeRequest(review)
            await gate.waitUntilEntered()
            XCTAssertEqual(try model.cancelCommand(id: review.id).state, "cancelling")
            await gate.release(); await model.closeAndWait()
            let status = try model.commandStatus(id: review.id)
            XCTAssertEqual(status.state, summary == .cancelled ? "cancelled" : "completed")
            XCTAssertEqual(status.result?.summary, summary); XCTAssertEqual(status.resourcesReleased, summary == .passed)
        }
    }

    func testReturnedReproductionCampaignRetainsCancellationAndFailureDistinction() async throws {
        for mode in ReturnedCampaignExecutor.Mode.allCases {
            let (model, root, _) = try await fixture(reproductionExecutor: { proposal, _, support, _ in
                let result = try await AutomationReproduction(cases: .init(root: support.appendingPathComponent("Cases"))).run(
                    frozen: proposal.frozen, originalAttemptID: proposal.originalAttemptID, approval: proposal.approval,
                    limits: proposal.limits, executor: ReturnedCampaignExecutor(mode: mode))
                if mode == .returnedCancellation {
                    try Data("archive unavailable".utf8).write(to: support.appendingPathComponent("Cases/Reproductions"))
                }
                return result
            })
            try await saveFailure(model: model, root: root)
            let review = try await model.prepareNativeConfirmation(.reproduction)
            try await model.confirmNativeRequest(review)
            let status = try model.commandStatus(id: review.id), outcome = try XCTUnwrap(status.reproduction)
            XCTAssertEqual(status.state, mode.isCancellation ? "cancelled" : "completed")
            XCTAssertEqual(status.resourcesReleased, outcome.resourcesReleased)
            XCTAssertEqual(outcome.complete, mode == .completed)
            XCTAssertEqual(outcome.attempts.first?.result.summary, mode == .returnedCancellation ? .cancelled : mode == .completed ? .passed : nil)
            XCTAssertEqual(outcome.interruption?.dispatchMayHaveOccurred, mode == .thrownCancellation || mode == .failed ? true : nil)
            XCTAssertEqual(try model.cancelCommand(id: review.id).state, status.state)
            if mode == .returnedCancellation { XCTAssertNotNil(model.message) }
        }
    }

    func testReturnedComparisonCampaignRetainsCancellationAndFailureDistinction() async throws {
        for mode in ReturnedCampaignExecutor.Mode.allCases {
            let (model, root, bundle) = try await fixture(comparisonExecutor: { proposal, _, _, support in
                let result = try await AutomationFixComparison(cases: .init(root: support.appendingPathComponent("Cases"))).run(
                    baseline: proposal.baseline, candidate: proposal.candidate, attemptsPerBuild: proposal.attemptsPerBuild,
                    beforeApproval: proposal.beforeApproval, afterApproval: proposal.afterApproval, limits: proposal.limits,
                    beforeExecutor: ReturnedCampaignExecutor(mode: mode), afterExecutor: NativeSearchFactExecutor())
                if mode == .returnedCancellation {
                    try Data("archive unavailable".utf8).write(to: support.appendingPathComponent("Cases/FixComparisons"))
                }
                return result
            })
            try await saveFailure(model: model, root: root)
            let fixed = root.appendingPathComponent("Fixed.app")
            try FileManager.default.copyItem(at: bundle, to: fixed)
            try Data("changed product fixture".utf8).write(to: fixed.appendingPathComponent("changed-resource"))
            model.selectFixedBundle(fixed)
            let review = try await model.prepareNativeConfirmation(.comparison)
            try await model.confirmNativeRequest(review)
            let status = try model.commandStatus(id: review.id), outcome = try XCTUnwrap(status.comparison)
            XCTAssertEqual(status.state, mode.isCancellation ? "cancelled" : "completed")
            XCTAssertEqual(status.resourcesReleased, outcome.resourcesReleased)
            XCTAssertEqual(outcome.complete, mode == .completed)
            XCTAssertEqual(outcome.before.first?.result.summary, mode == .returnedCancellation ? .cancelled : mode == .completed ? .passed : nil)
            XCTAssertEqual(outcome.interruption?.dispatchMayHaveOccurred, mode == .thrownCancellation || mode == .failed ? true : nil)
            XCTAssertEqual(try model.cancelCommand(id: review.id).state, status.state)
            if mode == .returnedCancellation { XCTAssertNotNil(model.message) }
        }
    }
}

private struct ReturnedCampaignExecutor: AutomationCampaignAttemptExecutor {
    enum Mode: CaseIterable, Sendable, Equatable {
        case returnedCancellation, thrownCancellation, failed, completed
        var isCancellation: Bool { self == .returnedCancellation || self == .thrownCancellation }
    }
    var mode: Mode
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String, budget: AutomationCampaignBudget) async throws -> AutomationAttemptReport {
        switch mode {
        case .returnedCancellation:
            return .init(attemptID: attemptID, result: AutomationAssessment.assess(plan: frozen.plan, attemptID: attemptID,
                subjectDispatched: false, subjectCompleted: false, observations: [], termination: .cancelled), receipts: [], resourcesReleased: true)
        case .thrownCancellation: throw CancellationError()
        case .failed: throw AutomationContractError.invalidIdentity
        case .completed: return try await NativeSearchFactExecutor().execute(frozen: frozen, approval: approval, attemptID: attemptID, budget: budget)
        }
    }
}

private actor ReturnedCancellationGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true; entryWaiter?.resume(); entryWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { entryWaiter = $0 } } }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}
#endif
