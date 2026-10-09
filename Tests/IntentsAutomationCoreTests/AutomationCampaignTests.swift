import XCTest
@testable import IntentsAutomationCore

final class AutomationCampaignTests: XCTestCase, @unchecked Sendable {
    private func baseline() throws -> AutomationFrozenCase {
        let app = AppIdentity(logicalID: "contract", bundleID: "example.Contract", platform: "ios")
        return try .init(plan: .init(id: "baseline", app: app, target: .init(id: "fixture-target", kind: .simulator), environmentID: "contract-fixture",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "ContractAction"),
            observations: [.init(id: "observe", kind: .ui, phase: .observe, operation: "ContractRead")],
            requirements: [.init(observationID: "observe", expected: .bool(true), proof: .visibleState, justification: "Unit contract requirement")]))
    }
    private func fixture() throws -> (AutomationFrozenCase, [AutomationMutationCase], AutomationSearchApproval, CapabilityProfile) {
        let base = try baseline(); var small = base.plan; small.id = "single"; small.execution.inputs["request"] = .text("approved equivalent")
        var large = small; large.id = "pair"; large.execution.inputs["context"] = .text(String(repeating: "unrelated valid context ", count: 5))
        let variants = try [AutomationMutationCase(frozen: .init(plan: small), recipeIDs: ["phrase"], kinds: [.alternatePhrasing], requiredCapabilities: ["fixture.recipe"], semanticJustification: "Unit-only equivalence fixture"),
            AutomationMutationCase(frozen: .init(plan: large), recipeIDs: ["phrase", "context"], kinds: [.alternatePhrasing, .unrelatedData], requiredCapabilities: ["fixture.recipe"], semanticJustification: "Unit-only compatible pair")]
        let run = RunApproval(runID: UUID().uuidString, app: base.plan.app, target: base.plan.target, environmentID: base.plan.environmentID, effects: [.observe], maximumActions: 20, disposable: true)
        return (base, variants, .init(run: run, approvedDigests: Set(([base] + variants.map(\.frozen)).map(\.digest))),
                .init(records: ["fixture.recipe": .init(state: .available, reason: "Unit test, not hardware qualification", probeVersion: "fixture", evidence: [])]))
    }
    private func store() throws -> AutomationCaseStore { try .init(root: URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)) }
    func testCorrectControlIsAssessedWithoutInventedFailureOrConfirmation() async throws {
        let (base, variants, approval, capabilities) = try fixture(), executor = CampaignFixtureExecutor(mode: .correct)
        let result = try await AutomationFailureSearch(cases: store()).run(baseline: base, mutations: variants, approval: approval, capabilities: capabilities, executor: executor)
        XCTAssertEqual(result.attempts.count, 5); XCTAssertEqual(result.counters.assessed, 5); XCTAssertEqual(result.counters.failed, 0)
        XCTAssertTrue(result.confirmations.isEmpty); XCTAssertNil(result.bestConfirmedCaseDigest)
        XCTAssertEqual(result.attempts.map(\.stage), [.baseline, .baseline, .baseline, .discovery, .discovery])
        XCTAssertEqual(result.usage.reservedSubjectOperations, 5); XCTAssertNil(result.usage.appModelRequests)
    }
    func testIntermittentControlRetainsAllFiveOutcomesAndFreshFinalReproduction() async throws {
        let (base, variants, approval, capabilities) = try fixture(), executor = CampaignFixtureExecutor(mode: .intermittent)
        let result = try await AutomationFailureSearch(cases: store()).run(baseline: base, mutations: variants, approval: approval, capabilities: capabilities, executor: executor)
        let confirmation = try XCTUnwrap(result.confirmations.first)
        XCTAssertEqual(confirmation.attempts.count, 5); XCTAssertGreaterThan(confirmation.matchingFailures, 0)
        XCTAssertGreaterThan(confirmation.assessedPasses, 0); XCTAssertEqual(confirmation.matchingFailures + confirmation.assessedPasses + confirmation.otherFailures + confirmation.unassessed, 5)
        XCTAssertEqual(result.finalReproduction?.attempts.count, 5)
        XCTAssertEqual(Set(result.attempts.map { $0.report.attemptID }).count, result.attempts.count)
    }
    func testMissingApprovalChangedOracleAndUnqualifiedFixtureStopBeforeExecutor() async throws {
        let (base, variants, approval, capabilities) = try fixture(), executor = CampaignFixtureExecutor(mode: .correct)
        var missing = approval; missing.approvedDigests = [base.digest]
        do { _ = try await AutomationFailureSearch(cases: store()).run(baseline: base, mutations: variants, approval: missing, capabilities: capabilities, executor: executor); XCTFail() } catch { }
        var changed = variants; var plan = changed[0].frozen.plan; plan.requirements[0].expected = .bool(false); changed[0].frozen = try .init(plan: plan)
        do { _ = try await AutomationFailureSearch(cases: store()).run(baseline: base, mutations: changed, approval: approval, capabilities: capabilities, executor: executor); XCTFail() } catch { }
        var writing = base.plan; writing.execution.effects.insert(.fixtureWrite); let frozen = try AutomationFrozenCase(plan: writing)
        var writes = approval; writes.run.effects.insert(.fixtureWrite); writes.approvedDigests = [frozen.digest]
        do { _ = try await AutomationFailureSearch(cases: store()).run(baseline: frozen, mutations: [], approval: writes, capabilities: capabilities, executor: executor); XCTFail() } catch { }
        let calls = await executor.calls; XCTAssertEqual(calls, 0)
    }
    func testAmbiguousDispatchStopsAllFreshAttemptsAndRetainsInterruption() async throws {
        let (base, variants, approval, capabilities) = try fixture(), executor = CampaignFixtureExecutor(mode: .ambiguous)
        let result = try await AutomationFailureSearch(cases: store()).run(baseline: base, mutations: variants, approval: approval, capabilities: capabilities, executor: executor)
        XCTAssertEqual(result.interruptions.count, 1); XCTAssertTrue(result.interruptions[0].dispatchMayHaveOccurred)
        XCTAssertEqual(result.usage.attempts, 1); XCTAssertEqual(result.counters.unresolved, 1)
        let calls = await executor.calls; XCTAssertEqual(calls, 1)
    }
    func testCapsAreSharedAtomicAndNeverRefundAmbiguousReservations() async throws {
        var limits = AutomationCampaignLimits(); limits.subjectOperations = 1; limits.uiActions = 1; limits.controllerCalls = 0
        let budget = try AutomationCampaignBudget(limits: limits)
        try await budget.reserveOperations(id: "first", phase: .subject, count: 1, uiActions: 1)
        do { try await budget.reserveOperations(id: "retry", phase: .subject, count: 1); XCTFail() } catch { }
        do { try await budget.reserveOperations(id: "first", phase: .setup, count: 1); XCTFail() } catch { }
        do { try await budget.reserveControllerCall(id: "model"); XCTFail() } catch { }
        let usage = await budget.snapshot(); XCTAssertEqual(usage.reservedSubjectOperations, 1); XCTAssertEqual(usage.reservedSetupOperations, 0); XCTAssertEqual(usage.controllerCalls, 0)
    }
    func testForeignRunFactsAreRetainedAsInterruptionAndNeverCountedAsPass() async throws {
        let (base, variants, approval, capabilities) = try fixture(), executor = CampaignFixtureExecutor(mode: .foreignRun)
        let result = try await AutomationFailureSearch(cases: store()).run(baseline: base, mutations: variants, approval: approval, capabilities: capabilities, executor: executor)
        XCTAssertTrue(result.attempts.isEmpty); XCTAssertEqual(result.interruptions.count, 1); XCTAssertEqual(result.counters.assessed, 0)
    }
    func testReducerRetainsOriginalFailureWhenSmallerCaseDoesNotReproduce() async throws {
        let (base, variants, approval, capabilities) = try fixture(), executor = CampaignFixtureExecutor(mode: .mutationsFail)
        let edge = AutomationReductionEdge(parentDigest: variants[0].frozen.digest, childDigest: base.digest, semanticJustification: "Unit fixture approved optional text removal")
        let result = try await AutomationFailureSearch(cases: store()).run(baseline: base, mutations: variants, reductions: [edge], approval: approval, capabilities: capabilities, executor: executor)
        XCTAssertEqual(result.bestConfirmedCaseDigest, variants[0].frozen.digest)
        let reduced = try XCTUnwrap(result.confirmations.first { $0.caseDigest == base.digest })
        XCTAssertEqual(reduced.attempts.count, 5); XCTAssertEqual(reduced.matchingFailures, 0); XCTAssertEqual(reduced.assessedPasses, 5)
        XCTAssertEqual(result.finalReproduction?.matchingFailures, 5); XCTAssertEqual(result.finalReproduction?.attempts.count, 5)
    }
    func testActualHostSubjectCannotChangeBehindAnUnchangedDisplayOperation() async throws {
        let (base, variants, approval, capabilities) = try fixture(), executor = CampaignFixtureExecutor(mode: .correct)
        var baselinePlan = base.plan
        baselinePlan.execution.hostProgram = .init(operations: [.init(id: "invoke", kind: .invoke, typeID: "ActualIntent", resultCodec: "noValue")])
        let frozenBase = try AutomationFrozenCase(plan: baselinePlan)
        var changed = variants[0].frozen.plan
        changed.execution.hostProgram = .init(operations: [.init(id: "invoke", kind: .invoke, typeID: "OtherIntent", resultCodec: "noValue")])
        let frozenChanged = try AutomationFrozenCase(plan: changed)
        var mutation = variants[0]; mutation.frozen = frozenChanged
        var granted = approval; granted.approvedDigests = [frozenBase.digest, frozenChanged.digest]
        do { _ = try await AutomationFailureSearch(cases: store()).run(baseline: frozenBase, mutations: [mutation], approval: granted, capabilities: capabilities, executor: executor); XCTFail("Changed actual intent accepted") } catch { }
        let calls = await executor.calls; XCTAssertEqual(calls, 0)
    }
    func testResourceReleaseRemainsAvailableAfterDeadlineButRejectsDuplicates() async throws {
        var limits = AutomationCampaignLimits(); limits.wallClockSeconds = 10
        let clock = CampaignTestClock(), budget = try AutomationCampaignBudget(limits: limits, now: { clock.read() })
        try await budget.reserveResourceRelease(id: "before-deadline")
        clock.advance(seconds: 11)
        await assertExhausted("wall clock") { try await budget.reserveOperations(id: "late", phase: .cleanup, count: 1) }
        await assertExhausted("wall clock") { try await budget.reserveAttempt(id: "late") }
        await assertExhausted("wall clock") { try await budget.reserveControllerCall(id: "late") }
        try await budget.reserveResourceRelease(id: "simulator")
        do { try await budget.reserveResourceRelease(id: "simulator"); XCTFail("Duplicate release accepted") } catch {
            XCTAssertEqual(error as? AutomationContractError, .ambiguousDispatch)
        }
        let usage = await budget.snapshot()
        XCTAssertEqual(usage.reservedResourceReleaseOperations, 2)
        XCTAssertEqual(usage.attempts, 0); XCTAssertEqual(usage.reservedCleanupOperations, 0); XCTAssertEqual(usage.controllerCalls, 0)
    }
    func testEachPhaseCapExhaustsOnlyItsOwnCounterWithExactLabel() async throws {
        let cases: [(AutomationSegment.Phase, WritableKeyPath<AutomationCampaignLimits, Int>, KeyPath<AutomationCampaignUsage, Int>, String)] = [
            (.subject, \.subjectOperations, \.reservedSubjectOperations, "subject operations"),
            (.setup, \.setupOperations, \.reservedSetupOperations, "setup operations"),
            (.observe, \.observerOperations, \.reservedObserverOperations, "observe operations"),
            (.cleanup, \.cleanupOperations, \.reservedCleanupOperations, "cleanup operations"),
        ]
        let counters: [KeyPath<AutomationCampaignUsage, Int>] = [\.reservedSubjectOperations, \.reservedSetupOperations, \.reservedObserverOperations, \.reservedCleanupOperations]
        for (phase, limit, counter, label) in cases {
            var limits = AutomationCampaignLimits(); limits[keyPath: limit] = 2
            let budget = try AutomationCampaignBudget(limits: limits)
            try await budget.reserveOperations(id: "fill", phase: phase, count: 2)
            await assertExhausted(label) { try await budget.reserveOperations(id: "over", phase: phase, count: 1) }
            let usage = await budget.snapshot()
            XCTAssertEqual(usage[keyPath: counter], 2, label)
            for other in counters where other != counter { XCTAssertEqual(usage[keyPath: other], 0, label) }
            XCTAssertEqual(usage.reservedUIActions, 0, label)
            for (otherPhase, _, otherCounter, _) in cases where otherCounter != counter {
                try await budget.reserveOperations(id: "other-" + otherPhase.rawValue, phase: otherPhase, count: 1)
            }
            try await budget.reserveOperations(id: "over", phase: phase, count: 0)
            let after = await budget.snapshot()
            XCTAssertEqual(after[keyPath: counter], 2, label)
            for other in counters where other != counter { XCTAssertEqual(after[keyPath: other], 1, label) }
        }
    }
    func testUIActionCapIsSharedAcrossPhasesAndRejectsWithoutChargingOperations() async throws {
        var limits = AutomationCampaignLimits(); limits.uiActions = 3
        let budget = try AutomationCampaignBudget(limits: limits)
        try await budget.reserveOperations(id: "setup", phase: .setup, count: 1, uiActions: 2)
        await assertExhausted("UI actions") { try await budget.reserveOperations(id: "observe", phase: .observe, count: 1, uiActions: 2) }
        var usage = await budget.snapshot()
        XCTAssertEqual(usage.reservedUIActions, 2); XCTAssertEqual(usage.reservedSetupOperations, 1); XCTAssertEqual(usage.reservedObserverOperations, 0)
        try await budget.reserveOperations(id: "observe", phase: .observe, count: 1, uiActions: 1)
        await assertExhausted("UI actions") { try await budget.reserveOperations(id: "cleanup", phase: .cleanup, count: 1, uiActions: 1) }
        usage = await budget.snapshot()
        XCTAssertEqual(usage.reservedUIActions, 3); XCTAssertEqual(usage.reservedObserverOperations, 1); XCTAssertEqual(usage.reservedCleanupOperations, 0)
    }
    func testInvalidCampaignLimitsAreRejected() throws {
        let invalid: [(String, (inout AutomationCampaignLimits) -> Void)] = [
            ("zero attempts", { $0.attempts = 0 }), ("zero subject operations", { $0.subjectOperations = 0 }),
            ("zero wall clock", { $0.wallClockSeconds = 0 }), ("negative setup", { $0.setupOperations = -1 }),
            ("attempts above cap", { $0.attempts = 100_001 }), ("observer above cap", { $0.observerOperations = 100_001 }),
            ("cleanup above cap", { $0.cleanupOperations = 100_001 }), ("UI actions above cap", { $0.uiActions = 100_001 }),
            ("controller above cap", { $0.controllerCalls = 100_001 }), ("wall clock above cap", { $0.wallClockSeconds = 100_001 }),
        ]
        for (name, mutate) in invalid {
            var limits = AutomationCampaignLimits(); mutate(&limits)
            XCTAssertThrowsError(try AutomationCampaignBudget(limits: limits), name) {
                XCTAssertEqual($0 as? AutomationContractError, .invalidPlan("Invalid campaign limits"), name)
            }
        }
        var boundary = AutomationCampaignLimits()
        boundary.setupOperations = 0; boundary.observerOperations = 0; boundary.cleanupOperations = 0; boundary.uiActions = 0; boundary.controllerCalls = 0
        boundary.attempts = 100_000; boundary.subjectOperations = 100_000; boundary.wallClockSeconds = 100_000
        XCTAssertNoThrow(try AutomationCampaignBudget(limits: boundary))
        XCTAssertNoThrow(try AutomationCampaignBudget(limits: .firstCampaign))
    }
    private func assertExhausted(_ label: String, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected exhausted(\(label))", file: file, line: line) } catch {
            XCTAssertEqual(error as? AutomationCampaignBudgetError, .exhausted(label), file: file, line: line)
        }
    }

}
private final class CampaignTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    func read() -> ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return instant }
    func advance(seconds: Int) { lock.lock(); defer { lock.unlock() }; instant = instant.advanced(by: .seconds(seconds)) }
}
private actor CampaignFixtureExecutor: AutomationCampaignAttemptExecutor {
    enum Mode { case correct, intermittent, ambiguous, foreignRun, mutationsFail }
    let mode: Mode
    var calls = 0
    init(mode: Mode) { self.mode = mode }
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String, budget: AutomationCampaignBudget) async throws -> AutomationAttemptReport {
        calls += 1
        try await budget.reserveOperations(id: attemptID + ".subject", phase: .subject, count: 1)
        if mode == .ambiguous { throw AutomationContractError.ambiguousDispatch }
        let plan = frozen.plan, value = !(mode == .intermittent && calls % 2 == 1) && !(mode == .mutationsFail && frozen.plan.id != "baseline")
        let receiptRunID = mode == .foreignRun ? "foreign-run" : approval.runID
        let observation = AutomationObservation(id: "observe", app: plan.app, target: plan.target, environmentID: plan.environmentID,
            attemptID: attemptID, stepID: "observe", route: .ui, proof: .visibleState, value: .bool(value))
        let receipts = [AutomationSegmentReceipt(scope: .init(runID: receiptRunID, attemptID: attemptID, segmentID: "subject", leaseGeneration: calls * 2), app: plan.app, target: plan.target, segmentID: "subject", route: .systemIntent, dispatched: true, completed: true),
            AutomationSegmentReceipt(scope: .init(runID: receiptRunID, attemptID: attemptID, segmentID: "observe", leaseGeneration: calls * 2 + 1), app: plan.app, target: plan.target, segmentID: "observe", route: .ui, dispatched: true, completed: true, observations: [observation])]
        return .init(attemptID: attemptID, result: AutomationAssessment.assess(plan: plan, attemptID: attemptID, subjectDispatched: true, subjectCompleted: true, observations: [observation]), receipts: receipts, resourcesReleased: true)
    }
}
