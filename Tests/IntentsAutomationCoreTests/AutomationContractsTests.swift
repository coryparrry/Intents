import XCTest
@testable import IntentsAutomationCore

final class AutomationContractsTests: XCTestCase {
    func testC01SharedTaggedValueGoldenRoundTrip() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "values", withExtension: "json", subdirectory: "Fixtures"))
        let values = try JSONDecoder().decode([AutomationValue].self, from: Data(contentsOf: url))
        XCTAssertEqual(values.count, 12)
        XCTAssertEqual(values[2], .integer("9007199254740993"))
        XCTAssertEqual(try JSONDecoder().decode([AutomationValue].self, from: JSONEncoder().encode(values)), values)
        XCTAssertNotEqual(AutomationValue.omission, .null)
    }
    func testC01RejectsUnknownKeysMalformedExactNumbersAndDepth() throws {
        for value in [#"{"kind":"text","value":"x","extra":true}"#, #"{"kind":"integer","value":"1e10"}"#, #"{"kind":"decimal","value":"NaN"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(AutomationValue.self, from: Data(value.utf8)))
        }
        var value = #"{"kind":"null"}"#
        for _ in 0..<20 { value = "{\"kind\":\"array\",\"value\":[\(value)]}" }
        XCTAssertThrowsError(try JSONDecoder().decode(AutomationValue.self, from: Data(value.utf8)))
    }
    func testC01UnicodeLimitsMatchJavaScriptCodeUnits() throws {
        let boundary = AutomationValue.text(String(repeating: "😀", count: 16_384))
        XCTAssertEqual(try JSONDecoder().decode(AutomationValue.self, from: JSONEncoder().encode(boundary)), boundary)
        XCTAssertThrowsError(try JSONEncoder().encode(AutomationValue.text(String(repeating: "😀", count: 16_385))))
        XCTAssertThrowsError(try JSONEncoder().encode(AutomationValue.entity(typeID: "Item", value: String(repeating: "😀", count: 513))))
    }
    func testC04UndrainedCommandsAndUnverifiedTerminationRetainLease() async throws {
        let manager = AutomationDeviceLeaseManager(), target = TargetIdentity(id: "udid", kind: .simulator)
        let lease = try await manager.acquire(runID: "run", target: target, control: .ui)
        do { try await manager.release(lease, commandsDrained: false, ownedRunnerTerminated: true); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationContractError, .commandsPending) }
        do { try await manager.release(lease, commandsDrained: true, ownedRunnerTerminated: false); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationContractError, .terminationUnverified) }
        do { _ = try await manager.acquire(runID: "other", target: target, control: .system); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
        try await manager.release(lease, commandsDrained: true, ownedRunnerTerminated: true)
        let next = try await manager.acquire(runID: "run", target: target, control: .system)
        XCTAssertGreaterThan(next.generation, lease.generation)
        do { try await manager.validate(lease); XCTFail() } catch { XCTAssertEqual(error as? AutomationContractError, .unknownLease) }
    }
    func testC06MacControlSerializesWholeLoginSession() async throws {
        let manager = AutomationDeviceLeaseManager()
        _ = try await manager.acquire(runID: "first", target: .init(id: "app1", kind: .nativeMac, loginSession: "login"), control: .ui)
        do { _ = try await manager.acquire(runID: "second", target: .init(id: "app2", kind: .nativeMac, loginSession: "login"), control: .ui); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
    }
    func testC05JournalRejectsConflictingAndAmbiguousRedispatchAfterReopen() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("journal.json")
        let journal = try AutomationJournal(url: url)
        let first = try await journal.begin(operationID: "first", digest: String(repeating: "a", count: 64))
        XCTAssertNil(first)
        let reopened = try AutomationJournal(url: url)
        do { _ = try await reopened.begin(operationID: "first", digest: String(repeating: "a", count: 64)); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationContractError, .ambiguousDispatch) }
        try await journal.complete(operationID: "first", digest: String(repeating: "a", count: 64), response: .bool(true))
        let response = try await journal.begin(operationID: "first", digest: String(repeating: "a", count: 64))
        XCTAssertEqual(response, .bool(true))
        do { _ = try await journal.begin(operationID: "first", digest: String(repeating: "b", count: 64)); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationContractError, .conflictingOperation) }
    }
    private func plan() -> AutomationCase {
        .init(id: "task", app: .init(logicalID: "app", bundleID: "com.example.App", platform: "ios"),
              target: .init(id: "udid", kind: .simulator), environmentID: "owned", execution:
                .init(id: "invoke", kind: .systemIntent, phase: .subject, operation: "CompleteTask"),
              observations: [.init(id: "read", kind: .systemQuery, phase: .observe, operation: "ReadTask")],
              requirements: [.init(observationID: "read", expected: .bool(true), proof: .persistedState, justification: "Approved completion requirement")])
    }
    private func observation(_ plan: AutomationCase, value: AutomationValue, proof: AutomationObservation.Proof = .persistedState) -> AutomationObservation {
        .init(id: "read", app: plan.app, target: plan.target, environmentID: plan.environmentID, attemptID: "attempt", stepID: "read",
              route: .systemQuery, proof: proof, value: value)
    }
    func testC15MissingBusinessEvidenceCannotPass() {
        let result = AutomationAssessment.assess(plan: plan(), attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: [])
        XCTAssertEqual(result.summary, .needsReview); XCTAssertFalse(result.assessed)
    }
    func testC20SuccessTextDoesNotProvePersistedChange() {
        let p = plan(), observation = observation(plan(), value: .text("Completed"), proof: .visibleState)
        XCTAssertEqual(AutomationAssessment.assess(plan: p, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: [observation]).summary, .needsReview)
        let unchanged = self.observation(p, value: .bool(false))
        XCTAssertEqual(AutomationAssessment.assess(plan: p, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: [unchanged]).summary, .assertionFailed)
    }
    func testCompleteIndependentStatePassesButWrongIdentityAndDuplicatesDoNot() {
        let p = plan(), correct = observation(plan(), value: .bool(true))
        XCTAssertEqual(AutomationAssessment.assess(plan: p, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: [correct]).summary, .passed)
        var wrong = correct; wrong.environmentID = "personal"
        XCTAssertEqual(AutomationAssessment.assess(plan: p, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: [wrong]).summary, .needsReview)
        XCTAssertEqual(AutomationAssessment.assess(plan: p, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: [correct, correct]).summary, .needsReview)
    }
    func testC14PopulationRetainsNotRunAndUnassessed() {
        var counts = ScopeCounters()
        counts.record(AutomationAssessment.assess(plan: plan(), attemptID: "a", subjectDispatched: false, subjectCompleted: false, observations: []))
        counts.record(AutomationAssessment.assess(plan: plan(), attemptID: "b", subjectDispatched: true, subjectCompleted: false, observations: []))
        XCTAssertEqual(counts.planned, 2); XCTAssertEqual(counts.notRun, 1); XCTAssertEqual(counts.unresolved, 1); XCTAssertEqual(counts.assessed, 0)
    }
    func testC14TimedOutAndUncertainDispatchRemainInUnresolvedPopulation() {
        var counts = ScopeCounters()
        var uncertain = AutomationAssessment.assess(plan: plan(), attemptID: "a", subjectDispatched: false, subjectCompleted: false, observations: [], termination: .timedOut)
        uncertain.subjectDispatchUncertain = true; counts.record(uncertain)
        counts.record(AutomationAssessment.assess(plan: plan(), attemptID: "b", subjectDispatched: true, subjectCompleted: false, observations: [], termination: .cancelled))
        XCTAssertEqual(counts.planned, 2); XCTAssertEqual(counts.unresolved, 2)
        XCTAssertEqual(counts.notRun, 0); XCTAssertEqual(counts.assessed, 0)
    }
    func testC21ObserverCannotRepairSubject() throws {
        var p = plan(); p.observations[0].effects = [.fixtureWrite]
        let approval = RunApproval(runID: "run", app: p.app, target: p.target, environmentID: p.environmentID, effects: [.observe, .fixtureWrite], maximumActions: 10, disposable: true)
        XCTAssertThrowsError(try PlanValidator.validate(p, approval: approval, capabilities: .init()))
    }
    func testC29CrashIsUnresolvedEvenIfOldObservationsExist() {
        let p = plan()
        XCTAssertEqual(AutomationAssessment.assess(plan: p, attemptID: "attempt", subjectDispatched: true, subjectCompleted: false,
                    observations: [observation(p, value: .bool(true))]).summary, .unresolved)
    }
}

extension AutomationContractsTests {
    func testReviewJournalInstancesCannotRedispatch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("journal.json")
        let first = try AutomationJournal(url: url), second = try AutomationJournal(url: url)
        _ = try await first.begin(operationID: "op", digest: String(repeating: "a", count: 64))
        do { _ = try await second.begin(operationID: "op", digest: String(repeating: "a", count: 64)); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationContractError, .ambiguousDispatch) }
    }
    func testReviewWrongRouteAndUndispatchedStateCannotPass() {
        let p = plan(); var value = observation(p, value: .bool(true)); value.route = .ui
        XCTAssertEqual(AutomationAssessment.assess(plan: p, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: [value]).summary, .needsReview)
        value.route = .systemQuery
        XCTAssertNotEqual(AutomationAssessment.assess(plan: p, attemptID: "attempt", subjectDispatched: false, subjectCompleted: true, observations: [value]).summary, .passed)
    }
    func testReviewLiveEnvironmentCannotReset() {
        var p = plan(); p.setup = [.init(id: "reset", kind: .ui, phase: .setup, operation: "reset", effects: [.reset])]
        let approval = RunApproval(runID: "run", app: p.app, target: p.target, environmentID: p.environmentID, effects: [.observe, .reset], maximumActions: 10, disposable: false)
        XCTAssertThrowsError(try PlanValidator.validate(p, approval: approval, capabilities: .init()))
    }
}

extension AutomationContractsTests {
    func testTaggedValueEncodingRejectsInvalidDatesPathsAndExactNumbers() {
        for value in [AutomationValue.integer("1e3"), .date("invalid", timeZone: "UTC"), .artifact(handle: "/etc/passwd", sha256: String(repeating: "a", count: 64))] {
            XCTAssertThrowsError(try JSONEncoder().encode(value))
        }
    }
}
