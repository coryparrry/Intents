import XCTest
@testable import IntentsAutomationCore

final class AutomationEntityBindingTests: XCTestCase, @unchecked Sendable {
    private func plan() -> AutomationCase {
        var setup = AutomationSegment(id: "lookup", kind: .systemQuery, phase: .setup, operation: "Query actual tasks", lifecycle: .persistedStateAcrossSegments)
        setup.hostProgram = .init(operations: [.init(id: "tasks", kind: .query, typeID: "Task", queryText: "Send invoice",
            properties: ["title": "text", "list": "text", "account": "text", "completed": "bool"])])
        var subject = AutomationSegment(id: "subject", kind: .systemIntent, phase: .subject, operation: "Complete selected task", lifecycle: .persistedStateAcrossSegments)
        subject.requiredCapabilities.append("apple.codec.entity")
        subject.hostProgram = .init(operations: [.init(id: "complete", kind: .invoke, typeID: "CompleteTask", resultCodec: "noValue")])
        subject.inputBindings = [.init(producerSegmentID: "lookup", outputID: "tasks", destination: .hostParameter,
            operationID: "complete", name: "task", uniqueEntity: .init(typeID: "Task",
                matchingProperties: ["title": .text("Send invoice"), "list": .text("Personal"), "account": .text("Synthetic account")]))]
        return .init(id: "binding", app: .init(logicalID: "app", bundleID: "example.App", platform: "ios"),
            target: .init(id: "owned", kind: .simulator), environmentID: "isolated-account", execution: subject, setup: [setup])
    }
    private func record(_ id: String, list: String = "Personal", account: String = "Synthetic account") -> AutomationValue {
        .object(["entity": .entity(typeID: "Task", value: id), "properties": .object([
            "title": .text("Send invoice"), "list": .text(list), "account": .text(account), "completed": .bool(false)])])
    }
    private func receipt(_ plan: AutomationCase, _ records: [AutomationValue]) -> AutomationSegmentReceipt {
        .init(scope: .init(runID: "run", attemptID: "attempt", segmentID: "lookup", leaseGeneration: 1),
            app: plan.app, target: plan.target, segmentID: "lookup", route: .systemQuery, dispatched: true, completed: true,
            verifiedOutputs: ["tasks": .array(records)], environmentID: plan.environmentID)
    }
    func testUniqueActualIdentityIsSelectedByDeclaredOwnershipRatherThanFirstResult() throws {
        let plan = plan(); try AutomationInputResolver.validate(plan: plan)
        let input = try AutomationInputResolver.resolve(segment: plan.execution,
            receipts: [receipt(plan, [record("work-id", list: "Work"), record("other-account", account: "Other"), record("actual-id")])],
            plan: plan, runID: "run", attemptID: "attempt")
        XCTAssertEqual(input.hostProgram?.operations[0].parameters["task"], .entity(typeID: "Task", value: "actual-id"))
        XCTAssertTrue(plan.execution.hostProgram!.operations[0].parameters.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(AutomationCase.self, from: JSONEncoder().encode(plan)), plan)
    }
    func testMissingAmbiguousRepeatedIdentityAndPartialPropertiesNeverBind() throws {
        let plan = plan()
        let partial = AutomationValue.object(["entity": .entity(typeID: "Task", value: "partial"), "properties": .object(["title": .text("Send invoice")])])
        for records in [[], [record("work", list: "Work")], [record("one"), record("two")], [record("same"), record("same")], [record("actual"), partial]] {
            XCTAssertThrowsError(try AutomationInputResolver.resolve(segment: plan.execution, receipts: [receipt(plan, records)], plan: plan, runID: "run", attemptID: "attempt"))
        }
    }
    func testForeignEnvironmentAndStaleAttemptCannotSupplyAnEntity() throws {
        let plan = plan()
        var foreign = receipt(plan, [record("actual")]); foreign.environmentID = "other-account"
        var legacy = foreign; legacy.environmentID = nil
        var stale = receipt(plan, [record("actual")]); stale.scope.attemptId = "previous"
        for value in [foreign, legacy, stale] {
            XCTAssertThrowsError(try AutomationInputResolver.resolve(segment: plan.execution, receipts: [value], plan: plan, runID: "run", attemptID: "attempt"))
        }
    }
    func testSelectionMustReferenceARealQueryAndDeclaredTypedProperties() throws {
        var plan = plan()
        plan.execution.inputBindings![0].uniqueEntity!.matchingProperties["invented"] = .text("not observed")
        XCTAssertThrowsError(try AutomationInputResolver.validate(plan: plan))
        plan = self.plan(); plan.execution.inputBindings![0].uniqueEntity!.matchingProperties["completed"] = .text("false")
        XCTAssertThrowsError(try AutomationInputResolver.validate(plan: plan))
        plan = self.plan(); plan.execution.inputBindings![0].uniqueEntity!.typeID = "OtherEntity"
        XCTAssertThrowsError(try AutomationInputResolver.validate(plan: plan))
    }
    func testExactIDLookupRejectsSubstitutedIdentityBeforeSubjectAcquisition() async throws {
        var plan = plan()
        plan.setup[0].hostProgram!.operations[0].queryText = nil
        plan.setup[0].hostProgram!.operations[0].queryIDs = ["requested"]
        let query = plan.setup[0].hostProgram!.operations[0]
        XCTAssertThrowsError(try AutomationEntitySelection.validateQueryOutput(.array([record("substitute")]), query: query))
        XCTAssertNoThrow(try AutomationEntitySelection.validateQueryOutput(.array([record("requested")]), query: query))
        XCTAssertNoThrow(try AutomationEntitySelection.validateQueryOutput(.array([]), query: query))
        let driver = EntityBindingDriver(output: .array([record("substitute")]))
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = AutomationCoordinator(leases: .init(), journal: try .init(url: root.appendingPathComponent("journal.json")))
        let approval = RunApproval(runID: "run", app: plan.app, target: plan.target, environmentID: plan.environmentID, effects: [.observe], maximumActions: 10, disposable: true)
        let report = try await coordinator.run(plan: plan, approval: approval, capabilities: syntheticEntityCodecCapabilities, attemptID: "attempt", driver: driver)
        XCTAssertEqual(report.result.summary, .inputUnavailable)
        XCTAssertFalse(report.result.subjectDispatched)
        let acquired = await driver.acquired; XCTAssertEqual(acquired, ["lookup"])
    }
    func testAmbiguousQueryStopsCoordinatorBeforeSubjectAcquisition() async throws {
        let plan = plan(), driver = EntityBindingDriver(output: .array([record("one"), record("two")]))
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = AutomationCoordinator(leases: .init(), journal: try .init(url: root.appendingPathComponent("journal.json")))
        let approval = RunApproval(runID: "run", app: plan.app, target: plan.target, environmentID: plan.environmentID, effects: [.observe], maximumActions: 10, disposable: true)
        let report = try await coordinator.run(plan: plan, approval: approval, capabilities: syntheticEntityCodecCapabilities, attemptID: "attempt", driver: driver)
        XCTAssertEqual(report.result.summary, .inputUnavailable); XCTAssertFalse(report.result.subjectDispatched)
        let acquired = await driver.acquired; XCTAssertEqual(acquired, ["lookup"])
    }
}
private actor EntityBindingDriver: AutomationRouteDriver {
    let output: AutomationValue
    var acquired: [String] = []
    init(output: AutomationValue) { self.output = output }
    func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) { acquired.append(segment.id) }
    func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) -> AutomationSegmentReceipt {
        .init(scope: scope, app: plan.app, target: plan.target, segmentID: segment.id, route: segment.kind,
            dispatched: true, completed: true, verifiedOutputs: ["tasks": output], environmentID: plan.environmentID)
    }
    func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) -> AutomationReleaseProof { .init(commandsDrained: true, runnerTerminated: true) }
}

private let syntheticEntityCodecCapabilities: CapabilityProfile = .init(records: ["apple.codec.entity": .init(state: .available, reason: "Synthetic driver conversion contract", probeVersion: "test", evidence: [])])
