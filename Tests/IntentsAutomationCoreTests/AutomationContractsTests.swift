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
    func testC01RejectsMalformedTagsKeysAndDigestsWhileDecoding() throws {
        let digest = String(repeating: "a", count: 64)
        let cases: [(json: String, reason: String)] = [
            (#"{"kind":"weird"}"#, "Unknown value tag"),
            (#"{"kind":"weird","value":1}"#, "Unknown value tag"),
            (#"{"kind":"null","value":1}"#, "Unknown value key"),
            (#"{"kind":"omission","value":null}"#, "Unknown value key"),
            (#"{"kind":"enum","typeId":"Priority","value":"high","timeZone":"UTC"}"#, "Unknown value key"),
            (#"{"kind":"date","value":"2026-10-05T21:00:00Z","timeZone":"Mars/Base"}"#, "Invalid timezone"),
            (#"{"kind":"artifact","value":"snapshot-1","sha256":"ABC"}"#, "Invalid digest"),
            ("{\"kind\":\"artifact\",\"value\":\"snapshot-1\",\"sha256\":\"\(String(repeating: "A", count: 64))\"}", "Invalid digest"),
            ("{\"kind\":\"artifact\",\"value\":\"snapshot-1\",\"sha256\":\"\(digest)a\"}", "Invalid digest"),
            ("{\"kind\":\"artifact\",\"value\":\"snapshot-1\",\"sha256\":\"\(digest.dropLast())g\"}", "Invalid digest"),
            (Self.nullArrayJSON(count: 1001), "Array limit"),
        ]
        for (json, reason) in cases {
            XCTAssertThrowsError(try JSONDecoder().decode(AutomationValue.self, from: Data(json.utf8)), json) { error in
                guard case DecodingError.dataCorrupted(let context) = error else { return XCTFail("\(json): \(error)") }
                XCTAssertEqual(context.debugDescription, reason, json)
            }
        }
        XCTAssertThrowsError(try JSONDecoder().decode(AutomationValue.self, from: Data(#"{"value":"x"}"#.utf8))) { error in
            guard case DecodingError.keyNotFound = error else { return XCTFail("\(error)") }
        }
    }
    func testC01RejectsInvalidIdentifiersDatesAndNodeBudget() throws {
        let digest = String(repeating: "a", count: 64)
        let invalid: [(json: String, value: AutomationValue)] = [
            (#"{"kind":"date","value":"2026-13-01","timeZone":"Europe/London"}"#, .date("2026-13-01", timeZone: "Europe/London")),
            (#"{"kind":"date","value":"2026-10-05","timeZone":"UTC"}"#, .date("2026-10-05", timeZone: "UTC")),
            (#"{"kind":"enum","typeId":"x y","value":"high"}"#, .enumeration(typeID: "x y", value: "high")),
            (#"{"kind":"enum","typeId":"Priority","value":"a/b"}"#, .enumeration(typeID: "Priority", value: "a/b")),
            (#"{"kind":"enum","typeId":"","value":"high"}"#, .enumeration(typeID: "", value: "high")),
            (#"{"kind":"entity","typeId":"x/y","value":"id"}"#, .entity(typeID: "x/y", value: "id")),
            (#"{"kind":"entity","typeId":"Task","value":""}"#, .entity(typeID: "Task", value: "")),
            ("{\"kind\":\"artifact\",\"value\":\"a/b\",\"sha256\":\"\(digest)\"}", .artifact(handle: "a/b", sha256: digest)),
            ("{\"kind\":\"artifact\",\"value\":\"\",\"sha256\":\"\(digest)\"}", .artifact(handle: "", sha256: digest)),
            (#"{"kind":"object","value":{"a b":{"kind":"null"}}}"#, .object(["a b": .null])),
            (#"{"kind":"object","value":{"":{"kind":"null"}}}"#, .object(["": .null])),
            (#"{"kind":"object","value":{"../etc":{"kind":"null"}}}"#, .object(["../etc": .null])),
            (#"{"kind":"array","value":[{"kind":"object","value":{"ok":{"kind":"enum","typeId":"x y","value":"v"}}}]}"#,
             .array([.object(["ok": .enumeration(typeID: "x y", value: "v")])])),
        ]
        for (json, value) in invalid {
            XCTAssertThrowsError(try JSONDecoder().decode(AutomationValue.self, from: Data(json.utf8)), json) { error in
                XCTAssertEqual(error as? AutomationContractError, .invalidPlan("Invalid tagged value"), json)
            }
            XCTAssertThrowsError(try JSONEncoder().encode(value), json) { error in
                XCTAssertEqual(error as? AutomationContractError, .invalidPlan("Invalid tagged value"), json)
            }
        }
        for value: AutomationValue in [.date("2026-10-05T21:00:00Z", timeZone: "Mars/Base"), .artifact(handle: "snapshot-1", sha256: "ABC"),
                                       .artifact(handle: "snapshot-1", sha256: String(repeating: "A", count: 64)),
                                       .array(Array(repeating: .null, count: 1001))] {
            XCTAssertThrowsError(try JSONEncoder().encode(value)) { error in
                XCTAssertEqual(error as? AutomationContractError, .invalidPlan("Invalid tagged value"))
            }
        }
        let overBudget = Self.wideArrayJSON(lastCount: 990)
        XCTAssertThrowsError(try JSONDecoder().decode(AutomationValue.self, from: Data(overBudget.utf8))) { error in
            XCTAssertEqual(error as? AutomationContractError, .invalidPlan("Value nesting/node limit"))
        }
        let wide = AutomationValue.array(Array(repeating: .array(Array(repeating: .null, count: 1000)), count: 9) + [.array(Array(repeating: .null, count: 990))])
        XCTAssertThrowsError(try JSONEncoder().encode(wide)) { error in
            XCTAssertEqual(error as? AutomationContractError, .invalidPlan("Value nesting/node limit"))
        }
    }
    func testC01AcceptsTaggedValueBoundaries() throws {
        let digest = String(repeating: "0123456789abcdef", count: 4)
        let boundaries: [AutomationValue] = [
            .array(Array(repeating: .null, count: 1000)),
            .artifact(handle: "snapshot_1.v2:part-3", sha256: digest),
            .enumeration(typeID: String(repeating: "T", count: 256), value: "A-z_0.9:x"),
            .object(["a.b:c-d_1": .null]),
            .date("2026-10-05T21:00:00.123Z", timeZone: "America/New_York"),
            .date("2026-10-05T21:00:00+01:00", timeZone: "UTC"),
        ]
        for value in boundaries {
            XCTAssertEqual(try JSONDecoder().decode(AutomationValue.self, from: JSONEncoder().encode(value)), value)
        }
        XCTAssertThrowsError(try JSONEncoder().encode(AutomationValue.enumeration(typeID: String(repeating: "T", count: 257), value: "v")))
        let atBudget = try JSONDecoder().decode(AutomationValue.self, from: Data(Self.wideArrayJSON(lastCount: 989).utf8))
        guard case .array(let groups) = atBudget else { return XCTFail("Expected array") }
        XCTAssertEqual(groups.count, 10)
        XCTAssertEqual(try JSONDecoder().decode(AutomationValue.self, from: JSONEncoder().encode(atBudget)), atBudget)
    }
    private static func nullArrayJSON(count: Int) -> String {
        "{\"kind\":\"array\",\"value\":[\(Array(repeating: #"{"kind":"null"}"#, count: count).joined(separator: ","))]}"
    }
    /// One outer array, ten inner arrays and their nulls: 11 + 9_000 + lastCount nodes at depth 2.
    private static func wideArrayJSON(lastCount: Int) -> String {
        let groups = Array(repeating: nullArrayJSON(count: 1000), count: 9) + [nullArrayJSON(count: lastCount)]
        return "{\"kind\":\"array\",\"value\":[\(groups.joined(separator: ","))]}"
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
