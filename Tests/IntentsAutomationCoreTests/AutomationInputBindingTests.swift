import XCTest
@testable import IntentsAutomationCore

final class AutomationInputBindingTests: XCTestCase, @unchecked Sendable {
    private func plan() -> AutomationCase {
        var producer = AutomationSegment(id: "setup", kind: .ui, phase: .setup, operation: "read real label", effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
        producer.uiProgram = .init(operations: [.init(id: "label", kind: .observeProperty, locator: .init(.testId, "item"), property: "value")])
        var subject = AutomationSegment(id: "subject", kind: .systemIntent, phase: .subject, operation: "Search", lifecycle: .persistedStateAcrossSegments)
        subject.requiredCapabilities.append("apple.codec.text")
        subject.hostProgram = .init(operations: [.init(id: "search", kind: .invoke, typeID: "SearchIntent", resultCodec: "noValue")])
        subject.inputBindings = [.init(producerSegmentID: "setup", outputID: "label", destination: .hostParameter, operationID: "search", name: "query")]
        return .init(id: "case", app: .init(logicalID: "app", bundleID: "example.App", platform: "ios"), target: .init(id: "owned", kind: .simulator), environmentID: "disposable", execution: subject, setup: [producer])
    }
    private func receipt(_ plan: AutomationCase, outputs: [String: AutomationValue]? = ["label": .text("real observed label")]) -> AutomationSegmentReceipt {
        .init(scope: .init(runID: "run", attemptID: "attempt", segmentID: "setup", leaseGeneration: 1), app: plan.app, target: plan.target,
              segmentID: "setup", route: .ui, dispatched: true, completed: true, verifiedOutputs: outputs)
    }
    func testFrozenBindingUsesTypedVerifiedOutputWithoutChangingOriginalPlan() throws {
        let plan = plan(); try AutomationInputResolver.validate(plan: plan)
        let bound = try AutomationInputResolver.resolve(segment: plan.execution, receipts: [receipt(plan)], plan: plan, runID: "run", attemptID: "attempt")
        XCTAssertEqual(bound.hostProgram?.operations[0].parameters["query"], .text("real observed label"))
        XCTAssertTrue(plan.execution.hostProgram!.operations[0].parameters.isEmpty)
    }
    func testURLDeclarationRejectsOtherwiseValidVerifiedTextBindingBeforeResolution() throws {
        let plan = plan(); try AutomationInputResolver.validate(plan: plan)
        let bound = try AutomationInputResolver.resolve(segment: plan.execution,
            receipts: [receipt(plan, outputs: ["label": .text("file:///private/tmp/customer.txt")])], plan: plan, runID: "run", attemptID: "attempt")
        XCTAssertEqual(bound.hostProgram?.operations[0].parameters["query"], .text("file:///private/tmp/customer.txt"))
        let catalog = ApplicationSurfaceCatalog(app: plan.app, systemActions: [.init(id: "SearchIntent", typeName: "SearchIntent", title: "URL", parameters: [.init(name: "query", family: "url", optional: true)], parametersComplete: true, compiled: true, registered: false, executed: false)], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [])
        XCTAssertThrowsError(try AutomationURLProgramContract.validate(plan, catalog: catalog))
    }
    func testMissingDuplicateStaleAndUncompletedOutputsCannotBecomeInput() throws {
        let plan = plan()
        var stale = receipt(plan); stale.scope.attemptId = "old"
        var foreign = receipt(plan); foreign.scope.runId = "other"
        var incomplete = receipt(plan); incomplete.completed = false
        for receipts in [[], [receipt(plan, outputs: nil)], [receipt(plan), receipt(plan)], [stale], [foreign], [incomplete]] {
            XCTAssertThrowsError(try AutomationInputResolver.resolve(segment: plan.execution, receipts: receipts, plan: plan, runID: "run", attemptID: "attempt"))
        }
    }
    func testBindingsRejectForwardReferencesMissingOutputsAndLiteralReplacement() throws {
        var invalid = plan(); invalid.execution.inputBindings![0].producerSegmentID = "subject"
        XCTAssertThrowsError(try AutomationInputResolver.validate(plan: invalid))
        invalid = plan(); invalid.execution.inputBindings![0].outputID = "invented"
        XCTAssertThrowsError(try AutomationInputResolver.validate(plan: invalid))
        invalid = plan(); invalid.execution.hostProgram!.operations[0].parameters["query"] = .text("literal")
        XCTAssertThrowsError(try AutomationInputResolver.validate(plan: invalid))
    }
    func testCoordinatorResolvesInputBeforeSubjectAcquisitionAndDispatch() async throws {
        let plan = plan(), driver = BindingContractDriver(includeOutput: true)
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let coordinator = AutomationCoordinator(leases: .init(), journal: try .init(url: root.appendingPathComponent("journal.json")))
        let approval = RunApproval(runID: "run", app: plan.app, target: plan.target, environmentID: plan.environmentID, effects: [.observe, .navigate], maximumActions: 10, disposable: true)
        let report = try await coordinator.run(plan: plan, approval: approval, capabilities: syntheticTextCodecCapabilities, attemptID: "attempt", driver: driver)
        XCTAssertTrue(report.result.subjectDispatched); XCTAssertTrue(report.result.subjectCompleted)
        let acquired = await driver.subjectAcquisitionInput, executed = await driver.subjectExecutionInput
        XCTAssertEqual(acquired, .text("actual")); XCTAssertEqual(executed, acquired)
    }
    func testCoordinatorDoesNotDispatchSubjectWithoutVerifiedProducerOutput() async throws {
        let plan = plan(), driver = BindingContractDriver(includeOutput: false)
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let coordinator = AutomationCoordinator(leases: .init(), journal: try .init(url: root.appendingPathComponent("journal.json")))
        let approval = RunApproval(runID: "run", app: plan.app, target: plan.target, environmentID: plan.environmentID, effects: [.observe, .navigate], maximumActions: 10, disposable: true)
        let report = try await coordinator.run(plan: plan, approval: approval, capabilities: syntheticTextCodecCapabilities, attemptID: "attempt", driver: driver)
        XCTAssertEqual(report.result.summary, .inputUnavailable); XCTAssertFalse(report.result.subjectDispatched)
        let executed = await driver.executed; XCTAssertEqual(executed, ["setup"])
    }
}
private actor BindingContractDriver: AutomationRouteDriver {
    var executed: [String] = []
    var subjectAcquisitionInput: AutomationValue?
    var subjectExecutionInput: AutomationValue?
    let includeOutput: Bool
    init(includeOutput: Bool) { self.includeOutput = includeOutput }
    func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) { if segment.phase == .subject { subjectAcquisitionInput = segment.hostProgram?.operations[0].parameters["query"] } }
    func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) -> AutomationSegmentReceipt {
        executed.append(segment.id)
        if segment.phase == .subject { subjectExecutionInput = segment.hostProgram?.operations[0].parameters["query"] }
        return .init(scope: scope, app: plan.app, target: plan.target, segmentID: segment.id, route: segment.kind, dispatched: true, completed: true,
            verifiedOutputs: includeOutput ? ["label": .text("actual")] : nil)
    }
    func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) -> AutomationReleaseProof { .init(commandsDrained: true, runnerTerminated: true) }
}

private let syntheticTextCodecCapabilities: CapabilityProfile = .init(records: ["apple.codec.text": .init(state: .available, reason: "Synthetic driver conversion contract", probeVersion: "test", evidence: [])])
