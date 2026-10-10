import XCTest
@testable import IntentsAutomationCore

final class AutomationEntityPropertyTests: XCTestCase, @unchecked Sendable {
    private struct Fixture {
        var plan: AutomationCase
        var approval: RunApproval
        var personalID: String
        var workID: String
        func records(personal: Bool = false, work: Bool = false) -> AutomationValue {
            .array([(personalID, "Personal", personal), (workID, "Work", work)].map { id, owner, completed in
                .object(["entity": .entity(typeID: "TaskEntity", value: id), "properties": .object([
                    "title": .text("Send invoice"), "owner": .text(owner), "completed": .bool(completed)])])
            })
        }
    }
    private func fixture() throws -> Fixture {
        let app = AppIdentity(logicalID: "app", bundleID: "example.App", platform: "ios", productDigest: String(repeating: "a", count: 64))
        let target = TargetIdentity(id: "owned", kind: .simulator)
        let query = AutomationHostProgram.Operation(id: "tasks", kind: .query, typeID: "TaskEntity", queryText: "Send invoice", properties: ["title": "text", "owner": "text", "completed": "bool"])
        var setup = AutomationSegment(id: "lookup", kind: .systemQuery, phase: .setup, operation: "Actual owned records", lifecycle: .persistedStateAcrossSegments)
        setup.hostProgram = .init(operations: [query])
        var subject = AutomationSegment(id: "subject", kind: .systemIntent, phase: .subject, operation: "Complete actual selected entity", effects: [.fixtureWrite], lifecycle: .persistedStateAcrossSegments)
        subject.requiredCapabilities.append("apple.codec.entity")
        subject.hostProgram = .init(operations: [.init(id: "complete", kind: .invoke, typeID: "CompleteTask", resultCodec: "noValue")])
        subject.inputBindings = [.init(producerSegmentID: "lookup", outputID: "tasks", destination: .hostParameter, operationID: "complete", name: "task", uniqueEntity: .init(typeID: "TaskEntity", matchingProperties: ["title": .text("Send invoice"), "owner": .text("Personal"), "completed": .bool(false)]))]
        var observer = setup; observer.id = "state"; observer.phase = .observe
        func requirement(owner: String, completed: Bool, segment: String, prefix: String) -> AutomationRequirement {
            .init(observationID: segment, expected: .bool(completed), proof: .appState,
                justification: "Approved positive property check on the actual owned query result", checkID: prefix + "." + owner.lowercased() + ".completed",
                entityProperty: .init(operationID: "tasks", selection: .init(typeID: "TaskEntity", matchingProperties: ["title": .text("Send invoice"), "owner": .text(owner)]), property: "completed"))
        }
        let plan = AutomationCase(id: "complete-selected", app: app, target: target, environmentID: "isolated",
            execution: subject, setup: [setup], observations: [observer], requirements: [requirement(owner: "Personal", completed: true, segment: "state", prefix: "business"), requirement(owner: "Work", completed: false, segment: "state", prefix: "business")],
            setupChecks: [requirement(owner: "Personal", completed: false, segment: "lookup", prefix: "fixture"), requirement(owner: "Work", completed: false, segment: "lookup", prefix: "fixture")])
        var approval = RunApproval(runID: "run", app: app, target: target, environmentID: "isolated", effects: [.observe, .fixtureWrite], maximumActions: 10, disposable: true)
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        try PlanValidator.validate(plan, approval: approval, capabilities: syntheticEntityCodecCapabilities)
        return .init(plan: plan, approval: approval, personalID: UUID().uuidString, workID: UUID().uuidString)
    }
    private func observation(_ fixture: Fixture, value: AutomationValue) -> AutomationObservation {
        .init(id: "state", app: fixture.plan.app, target: fixture.plan.target, environmentID: fixture.plan.environmentID,
            attemptID: "attempt", stepID: "state", route: .systemQuery, proof: .appState, value: value)
    }
    func testFreshEntityIDsDoNotEnterExpectedValuesAndWrongRecordFailsBothChecks() throws {
        for _ in 0..<3 {
            let fixture = try fixture()
            let passed = AutomationAssessment.assess(plan: fixture.plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: [observation(fixture, value: fixture.records(personal: true))])
            XCTAssertEqual(passed.summary, .passed); XCTAssertTrue(passed.assessed)
            let wrong = AutomationAssessment.assess(plan: fixture.plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: [observation(fixture, value: fixture.records(work: true))])
            XCTAssertEqual(wrong.summary, .assertionFailed); XCTAssertTrue(wrong.evidenceComplete)
            XCTAssertEqual(wrong.failedObservations, ["business.personal.completed", "business.work.completed"])
        }
    }
    func testSuccessReceiptDoesNotPassMissingSaveOrIncompleteIndependentQuery() throws {
        let fixture = try fixture()
        let missingSave = AutomationAssessment.assess(plan: fixture.plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: [observation(fixture, value: fixture.records())])
        XCTAssertEqual(missingSave.summary, .assertionFailed)
        let partial = AutomationValue.array([.object(["entity": .entity(typeID: "TaskEntity", value: fixture.personalID), "properties": .object(["owner": .text("Personal")])])])
        for value in [.text("Success"), .array([]), partial] {
            let result = AutomationAssessment.assess(plan: fixture.plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: [observation(fixture, value: value)])
            XCTAssertEqual(result.summary, .needsReview); XCTAssertFalse(result.evidenceComplete)
        }
    }
    func testDuplicateIdentityAmbiguousOwnershipAndForeignScopeNeverPass() throws {
        let fixture = try fixture()
        guard case .array(let records) = fixture.records(personal: true) else { return XCTFail() }
        var ambiguous = records
        ambiguous.append(.object(["entity": .entity(typeID: "TaskEntity", value: UUID().uuidString), "properties": .object(["title": .text("Send invoice"), "owner": .text("Personal"), "completed": .bool(true)])]))
        for value in [AutomationValue.array(records + [records[0]]), .array(ambiguous)] {
            let result = AutomationAssessment.assess(plan: fixture.plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: [observation(fixture, value: value)])
            XCTAssertNotEqual(result.summary, .passed)
        }
        for flag in 0..<4 {
            var fact = observation(fixture, value: fixture.records(personal: true))
            switch flag { case 0: fact.environmentID = "foreign"; case 1: fact.attemptID = "old"; case 2: fact.complete = false; default: fact.fresh = false }
            XCTAssertEqual(AutomationAssessment.assess(plan: fixture.plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: [fact]).summary, .needsReview)
        }
    }
    func testProjectionSelectsNamedOperationInMultiQueryObservation() throws {
        var fixture = try fixture()
        fixture.plan.observations[0].hostProgram?.operations.append(.init(id: "other", kind: .query, typeID: "OtherEntity", queryText: "other", properties: ["title": "text"]))
        let value = AutomationValue.object(["tasks": fixture.records(personal: true), "other": .array([])])
        XCTAssertEqual(AutomationAssessment.assess(plan: fixture.plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: [observation(fixture, value: value)]).summary, .passed)
    }
    func testUnsupportedCodecCircularSelectionAndStrongerProofFailBeforeDispatch() throws {
        let fixture = try fixture()
        for mutation in 0..<7 {
            var plan = fixture.plan
            switch mutation {
            case 0: plan.requirements[0].expected = .text("true")
            case 1: plan.requirements[0].entityProperty?.property = "missing"
            case 2: plan.requirements[0].entityProperty?.operationID = "missing"
            case 3: plan.requirements[0].entityProperty?.selection.matchingProperties["completed"] = .bool(true)
            case 4: plan.requirements[0].proof = .persistedState
            case 5: plan.requirements[0].checkID = nil
            default: plan.requirements[1].checkID = plan.requirements[0].checkID
            }
            var approval = fixture.approval; approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
            XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: syntheticEntityCodecCapabilities))
        }
        var unapproved = fixture.approval; unapproved.approvedCaseDigest = nil
        XCTAssertThrowsError(try PlanValidator.validate(fixture.plan, approval: unapproved, capabilities: syntheticEntityCodecCapabilities))
    }
    func testFixturePreconditionsStopBeforeSubjectAndRetainCompletedSetup() async throws {
        let fixture = try fixture()
        for mode in [PropertyContractDriver.Mode.invalidFixture, .missingFixtureOutput, .foreignFixture] {
            let driver = PropertyContractDriver(fixture: fixture, mode: mode)
            let report = try await run(fixture, driver: driver)
            XCTAssertEqual(report.result.summary, .invalidFixture); XCTAssertFalse(report.result.subjectDispatched)
            XCTAssertEqual(report.receipts.map(\.segmentID), mode == .foreignFixture ? [] : ["lookup"])
            XCTAssertTrue(report.resourcesReleased)
            let calls = await driver.subjectCalls; XCTAssertEqual(calls, 0)
        }
    }
    func testLaterMutationCannotInvalidateApprovedFixtureQuery() async throws {
        let fixture = try fixture()
        var plan = fixture.plan
        var mutation = plan.execution; mutation.id = "late-mutation"; mutation.phase = .setup
        mutation.inputBindings = nil
        plan.setup.append(mutation)
        var approval = fixture.approval; approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: syntheticEntityCodecCapabilities))
        let driver = PropertyContractDriver(fixture: fixture, mode: .correct)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await AutomationCoordinator(leases: .init(), journal: .init(url: root.appendingPathComponent("journal.json")))
                .run(plan: plan, approval: approval, capabilities: syntheticEntityCodecCapabilities, attemptID: "attempt", driver: driver)
            XCTFail("Invalid fixture ordering must be rejected before any dispatch")
        } catch {}
        let calls = await driver.subjectCalls; XCTAssertEqual(calls, 0)
        let report = try await run(fixture, driver: PropertyContractDriver(fixture: fixture, mode: .correct))
        XCTAssertThrowsError(try AutomationRecordedEvidence.validate(report: report, plan: plan, expectedRunID: "run"))
        var circular = fixture.plan
        circular.requirements[0].entityProperty?.selection.matchingProperties["completed"] = .bool(true)
        XCTAssertThrowsError(try AutomationRecordedEvidence.validate(report: report, plan: circular, expectedRunID: "run"))
    }
    func testWrongMutationRemainsExecutableAndSavedFactsCannotContradictFixture() async throws {
        let fixture = try fixture()
        let wrongDriver = PropertyContractDriver(fixture: fixture, mode: .wrongRecord)
        let wrong = try await run(fixture, driver: wrongDriver)
        XCTAssertEqual(wrong.result.summary, .assertionFailed); XCTAssertTrue(wrong.result.subjectCompleted)
        let input = await wrongDriver.subjectInput
        XCTAssertEqual(input, .entity(typeID: "TaskEntity", value: fixture.personalID))
        try AutomationRecordedEvidence.validate(report: wrong, plan: fixture.plan, expectedRunID: "run")
        let correct = try await run(fixture, driver: PropertyContractDriver(fixture: fixture, mode: .correct))
        XCTAssertEqual(correct.result.summary, .passed)
        var contradictory = correct; contradictory.receipts[0].verifiedOutputs?["tasks"] = fixture.records(personal: true)
        XCTAssertThrowsError(try AutomationRecordedEvidence.validate(report: contradictory, plan: fixture.plan, expectedRunID: "run"))
    }
    func testExpectationsAndFixtureChecksAreAbsentFromSubjectPayload() throws {
        let fixture = try fixture()
        let data = try fixture.plan.execution.hostProgram!.payload(scope: .init(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: 1), app: fixture.plan.app, route: .systemIntent, phase: .subject)
        let text = String(decoding: data, as: UTF8.self)
        for rubric in ["business.personal.completed", "fixture.personal.completed", "completed", "Personal", "Work"] { XCTAssertFalse(text.contains(rubric)) }
        let roundTrip = try JSONDecoder().decode(AutomationCase.self, from: JSONEncoder().encode(fixture.plan))
        XCTAssertEqual(roundTrip, fixture.plan)
        XCTAssertEqual(try AutomationFrozenCase.planDigest(roundTrip), try AutomationFrozenCase.planDigest(fixture.plan))
    }
    private func run(_ fixture: Fixture, driver: PropertyContractDriver) async throws -> AutomationAttemptReport {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        return try await AutomationCoordinator(leases: .init(), journal: .init(url: root.appendingPathComponent("journal.json"))).run(plan: fixture.plan, approval: fixture.approval, capabilities: syntheticEntityCodecCapabilities, attemptID: "attempt", driver: driver)
    }
    private actor PropertyContractDriver: AutomationRouteDriver {
        enum Mode { case correct, wrongRecord, invalidFixture, missingFixtureOutput, foreignFixture }
        let fixture: Fixture
        let mode: Mode
        var subjectCalls = 0
        var subjectInput: AutomationValue?
        init(fixture: Fixture, mode: Mode) { self.fixture = fixture; self.mode = mode }
        func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) {}
        func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) -> AutomationSegmentReceipt {
            if segment.phase == .subject { subjectCalls += 1; subjectInput = segment.hostProgram?.operations[0].parameters["task"] }
            let value = segment.phase == .setup ? fixture.records(personal: mode == .invalidFixture) : fixture.records(personal: mode == .correct, work: mode == .wrongRecord)
            let outputs: [String: AutomationValue]? = segment.phase == .setup && mode == .missingFixtureOutput ? nil : [segment.phase == .subject ? "complete" : "tasks": segment.phase == .subject ? .omission : value]
            let observations: [AutomationObservation] = segment.phase == .observe ? [.init(id: segment.id, app: plan.app, target: plan.target, environmentID: plan.environmentID, attemptID: scope.attemptId, stepID: segment.id, route: .systemQuery, proof: .appState, value: value)] : []
            return .init(scope: scope, app: plan.app, target: plan.target, segmentID: segment.id, route: segment.kind, dispatched: true, completed: true, observations: observations, verifiedOutputs: outputs, environmentID: mode == .foreignFixture && segment.phase == .setup ? "foreign" : plan.environmentID)
        }
        func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) -> AutomationReleaseProof { .init(commandsDrained: true, runnerTerminated: true) }
    }
}

private let syntheticEntityCodecCapabilities: CapabilityProfile = .init(records: ["apple.codec.entity": .init(state: .available, reason: "Synthetic driver conversion contract", probeVersion: "test", evidence: [])])
