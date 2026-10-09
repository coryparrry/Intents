import XCTest
@testable import IntentsAutomationCore

final class AutomationUIFailureSearchArchiveTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> (URL, AutomationFrozenCase, RunApproval, AutomationMutationCase) {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let app = AppIdentity(logicalID: "selected", bundleID: "example.UI", platform: "ios")
        let target = TargetIdentity(id: UUID().uuidString, kind: .simulator)
        let approval = RunApproval(runID: "archive-run", app: app, target: target, environmentID: "owned", effects: [.observe, .navigate], maximumActions: 30, disposable: true)
        let plan = try AutomationUIOnlyPlanner.compile(app: app, target: target, instruction: "Open tasks", endpoint: "Tasks", expectedVisibleText: "Complete", approval: approval, localeIdentifier: "en_GB")
        let base = try AutomationFrozenCase(plan: plan)
        let phrase = try AutomationGoalPhraseVariation.propose(baseline: base, instruction: "Show tasks", semanticJustification: "Same approved destination")
        return (root, base, approval, phrase)
    }
    func testSavedSearchRevalidatesCanonicalFactsAndRefusesOverwrite() async throws {
        let (root, base, approval, phrase) = try fixture(), cases = try AutomationCaseStore(root: root)
        let report = try await AutomationFailureSearch(cases: cases).run(baseline: base, mutations: [phrase],
            approval: .init(run: approval, approvedDigests: [base.digest, phrase.frozen.digest]), capabilities: .init(), executor: ArchiveFactExecutor())
        let record = AutomationUIFailureSearchRecord(id: "search", runID: approval.runID, baseline: base, mutations: [phrase], report: report)
        let archive = try AutomationUIFailureSearchArchive(caseStoreRoot: root)
        try await archive.save(record)
        let loaded = try await archive.load(id: "search")
        XCTAssertEqual(loaded.report, report); XCTAssertEqual(loaded.verificationScope, "historicalValidatedFacts")
        let listed = try await archive.records(); XCTAssertEqual(listed.count, 1)
        let reopened = try AutomationUIFailureSearchArchive(caseStoreRoot: root)
        let reopenedRecords = try await reopened.records()
        XCTAssertEqual(reopenedRecords, listed)
        do { try await archive.save(record); XCTFail("Overwrote immutable search") } catch {}
        do { _ = try await archive.load(id: "../search"); XCTFail("Traversed search path") } catch {}
    }
    func testExistingSearchPathMustBeAnUnaliasedDirectory() throws {
        for alias in [false, true] {
            let (root, _, _, _) = try fixture()
            _ = try AutomationCaseStore(root: root)
            let searchPath = root.appendingPathComponent("Searches")
            if alias {
                let elsewhere = root.appendingPathComponent("Elsewhere")
                try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
                try FileManager.default.createSymbolicLink(at: searchPath, withDestinationURL: elsewhere)
            } else {
                try Data("invalid".utf8).write(to: searchPath)
            }
            XCTAssertThrowsError(try AutomationUIFailureSearchArchive(caseStoreRoot: root))
        }
    }
    func testFabricatedAggregateOrForeignRunCannotBecomeSavedConfirmation() async throws {
        let (root, base, approval, phrase) = try fixture(), cases = try AutomationCaseStore(root: root)
        let report = try await AutomationFailureSearch(cases: cases).run(baseline: base, mutations: [phrase],
            approval: .init(run: approval, approvedDigests: [base.digest, phrase.frozen.digest]), capabilities: .init(), executor: ArchiveFactExecutor())
        let archive = try AutomationUIFailureSearchArchive(caseStoreRoot: root)
        var falseCounters = report; falseCounters.counters.failed += 1
        var falseConfirmation = report
        falseConfirmation.confirmations = [.init(caseDigest: base.digest, signature: ["business.visible-text"], attempts: report.attempts.prefix(5).map { $0.report.attemptID }, matchingFailures: 5, assessedPasses: 0, otherFailures: 0, unassessed: 0)]
        for (id, candidate, runID) in [("counts", falseCounters, approval.runID), ("confirmation", falseConfirmation, approval.runID), ("foreign", report, "other-run")] {
            do { try await archive.save(.init(id: id, runID: runID, baseline: base, mutations: [phrase], report: candidate)); XCTFail("Accepted fabricated or foreign saved facts") } catch {}
        }
        let listed = try await archive.records(); XCTAssertTrue(listed.isEmpty)
    }
    func testStageCoverageDuplicateConfirmationsAndAttemptCountsMustMatchDurableFacts() async throws {
        let (root, base, approval, phrase) = try fixture(), cases = try AutomationCaseStore(root: root)
        let report = try await AutomationFailureSearch(cases: cases).run(baseline: base, mutations: [phrase],
            approval: .init(run: approval, approvedDigests: [base.digest, phrase.frozen.digest]), capabilities: .init(), executor: ArchiveFactExecutor(failing: true))
        XCTAssertEqual(report.confirmations.count, 2)
        let archive = try AutomationUIFailureSearchArchive(caseStoreRoot: root)
        try await archive.save(.init(id: "genuine", runID: approval.runID, baseline: base, mutations: [phrase], report: report))
        for index in 0..<7 {
            var changed = report
            switch index {
            case 0: changed.attempts[3].stage = .baseline
            case 1: changed.confirmations[0].attempts.removeLast(); changed.confirmations[0].matchingFailures -= 1
            case 2: changed.confirmations[1] = changed.confirmations[0]
            case 3: changed.usage.attempts = 0
            case 4: changed.confirmations.removeLast()
            case 5: changed.confirmations.reverse()
            default: changed.bestConfirmedCaseDigest = phrase.frozen.digest; changed.finalReproduction?.caseDigest = phrase.frozen.digest
            }
            do { try await archive.save(.init(id: "tamper-\(index)", runID: approval.runID, baseline: base, mutations: [phrase], report: changed)); XCTFail("Accepted impossible campaign aggregate") } catch {}
        }
    }
    func testFinalReproductionCannotSwitchToAnotherFailureSignature() async throws {
        let (root, original, approval, _) = try fixture()
        var plan = original.plan
        plan.requirements.append(.init(observationID: plan.observations[0].id, expected: .text("Other"), proof: .visibleState,
            justification: "Separate source-contract assertion", checkID: "business.alternative"))
        let base = try AutomationFrozenCase(plan: plan)
        let phrase = try AutomationGoalPhraseVariation.propose(baseline: base, instruction: "Show tasks", semanticJustification: "Same approved destination")
        let report = try await AutomationFailureSearch(cases: .init(root: root)).run(baseline: base, mutations: [phrase],
            approval: .init(run: approval, approvedDigests: [base.digest, phrase.frozen.digest]), capabilities: .init(),
            executor: ArchiveFactExecutor(failing: true, switchFinalSignature: true))
        XCTAssertEqual(report.finalReproduction?.matchingFailures, 0)
        XCTAssertEqual(report.finalReproduction?.otherFailures, 5)
        let archive = try AutomationUIFailureSearchArchive(caseStoreRoot: root)
        try await archive.save(.init(id: "genuine-signature", runID: approval.runID, baseline: base, mutations: [phrase], report: report))
        var changed = report
        changed.finalReproduction?.signature = ["business.alternative"]
        changed.finalReproduction?.matchingFailures = 5; changed.finalReproduction?.otherFailures = 0
        do { try await archive.save(.init(id: "changed-signature", runID: approval.runID, baseline: base, mutations: [phrase], report: changed)); XCTFail("A different final failure became reproduction") } catch {}
    }
    func testInterruptedSearchRetainsApprovedDefinitionsWithoutManufacturingAttempts() async throws {
        let (root, base, approval, phrase) = try fixture(), cases = try AutomationCaseStore(root: root)
        let report = try await AutomationFailureSearch(cases: cases).run(baseline: base, mutations: [phrase],
            approval: .init(run: approval, approvedDigests: [base.digest, phrase.frozen.digest]), capabilities: .init(), executor: ArchiveInterruptedExecutor())
        XCTAssertTrue(report.attempts.isEmpty); XCTAssertEqual(report.interruptions.count, 1)
        let archive = try AutomationUIFailureSearchArchive(caseStoreRoot: root)
        try await archive.save(.init(id: "interrupted", runID: approval.runID, baseline: base, mutations: [phrase], report: report))
        let loaded = try await archive.load(id: "interrupted")
        XCTAssertNil(loaded.report.finalReproduction); XCTAssertTrue(loaded.report.attempts.isEmpty)
    }
}
private actor ArchiveInterruptedExecutor: AutomationCampaignAttemptExecutor {
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String, budget: AutomationCampaignBudget) throws -> AutomationAttemptReport { throw CancellationError() }
}
private actor ArchiveFactExecutor: AutomationCampaignAttemptExecutor {
    let failing: Bool
    let switchFinalSignature: Bool
    private var calls = 0
    init(failing: Bool = false, switchFinalSignature: Bool = false) { self.failing = failing; self.switchFinalSignature = switchFinalSignature }
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String, budget: AutomationCampaignBudget) -> AutomationAttemptReport {
        // Canonical source-contract fixture; not accessibility capture/device proof.
        let plan = frozen.plan, observer = plan.observations[0]
        calls += 1
        let value: AutomationValue = switchFinalSignature && calls > 14 ? .text("Complete") : failing ? .text("Other") : plan.requirements[0].expected
        let fact = AutomationObservation(id: observer.id, app: plan.app, target: plan.target, environmentID: plan.environmentID,
            attemptID: attemptID, stepID: observer.id, route: .ui, proof: .visibleState, value: value)
        let receipts = [plan.execution, observer].enumerated().map { index, segment in
            AutomationSegmentReceipt(scope: .init(runID: approval.runID, attemptID: attemptID, segmentID: segment.id, leaseGeneration: index + 1),
                app: plan.app, target: plan.target, segmentID: segment.id, route: .ui, dispatched: true, completed: true,
                observations: segment.phase == .observe ? [fact] : [])
        }
        return .init(attemptID: attemptID, result: AutomationAssessment.assess(plan: plan, attemptID: attemptID, subjectDispatched: true,
            subjectCompleted: true, observations: [fact]), receipts: receipts, resourcesReleased: true)
    }
}
