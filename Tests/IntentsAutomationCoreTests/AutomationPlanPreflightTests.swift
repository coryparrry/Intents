import XCTest
@testable import IntentsAutomationCore

final class AutomationPlanPreflightTests: XCTestCase {
    private func fixture() -> (AutomationCase, RunApproval) {
        let app = AppIdentity(logicalID: "app", bundleID: "example.App", platform: "ios")
        let target = TargetIdentity(id: "owned", kind: .simulator)
        let subject = AutomationSegment(id: "subject", kind: .systemIntent, phase: .subject, operation: "actual")
        return (.init(id: "case", app: app, target: target, environmentID: "owned", execution: subject),
                .init(runID: "run", app: app, target: target, environmentID: "owned", effects: [.observe, .navigate], maximumActions: 30, disposable: true))
    }
    func testGraphCapsProducerOperationsRatherThanLowLevelUISteps() throws {
        var (plan, approval) = fixture()
        plan.setup = (1...3).map { .init(id: "setup.\($0)", kind: .ui, phase: .setup, operation: "setup") }
        XCTAssertNoThrow(try PlanValidator.validate(plan, approval: approval, capabilities: .init()))
        plan.setup.append(.init(id: "setup.4", kind: .ui, phase: .setup, operation: "setup"))
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: .init()))
        var producer = AutomationSegment(id: "query", kind: .systemQuery, phase: .setup, operation: "query", lifecycle: .persistedStateAcrossSegments)
        producer.hostProgram = .init(operations: (1...4).map { .init(id: "op.\($0)", kind: .query, typeID: "ActualEntity", queryText: "actual") })
        plan.setup = [producer]
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: .init()))
        var ui = AutomationSegment(id: "ui", kind: .ui, phase: .setup, operation: "navigation", effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
        ui.uiProgram = .init(operations: (1...30).map { .init(id: "step.\($0)", kind: .locate, locator: .init(.testId, "actual")) })
        plan.setup = [ui]
        XCTAssertNoThrow(try PlanValidator.validate(plan, approval: approval, capabilities: .init()))
    }
    func testInvalidProgramShapeRouteAndAppleLifecycleFailInPreflight() throws {
        var (plan, approval) = fixture()
        plan.execution.hostProgram = .init(operations: [.init(id: "invoke", kind: .invoke, typeID: "Actual", resultCodec: "noValue")])
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: .init()))
        plan.execution.lifecycle = .persistedStateAcrossSegments
        XCTAssertNoThrow(try PlanValidator.validate(plan, approval: approval, capabilities: .init()))
        plan.execution.kind = .systemQuery
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: .init()))
        plan.execution.kind = .systemIntent
        plan.execution.uiProgram = .init(operations: [.init(id: "read", kind: .observeProperty, locator: .init(.testId, "actual"), property: "text")])
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: .init()))
        plan.execution.hostProgram = nil; plan.execution.kind = .ui
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: .init()))
        plan.execution.effects.insert(.navigate)
        XCTAssertNoThrow(try PlanValidator.validate(plan, approval: approval, capabilities: .init()))
        plan.execution.uiProgram?.operations[0].property = "unknown"
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: .init()))
    }
    func testDeferredUIBindingChecksShapeWithoutSubstitutingFrozenInput() throws {
        var (plan, approval) = fixture()
        var producer = AutomationSegment(id: "read", kind: .ui, phase: .setup, operation: "read", effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
        producer.uiProgram = .init(operations: [.init(id: "text", kind: .observeProperty, locator: .init(.testId, "actual"), property: "text")])
        var subject = AutomationSegment(id: "subject", kind: .ui, phase: .subject, operation: "fill", effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
        subject.uiProgram = .init(operations: [.init(id: "fill", kind: .fillBinding, locator: .init(.testId, "field"), binding: "fresh")])
        subject.inputBindings = [.init(producerSegmentID: "read", outputID: "text", destination: .uiBinding, name: "fresh")]
        plan.setup = [producer]; plan.execution = subject
        XCTAssertNoThrow(try PlanValidator.validate(plan, approval: approval, capabilities: .init()))
        XCTAssertTrue(plan.execution.uiProgram!.bindings.isEmpty)
        XCTAssertThrowsError(try AutomationInputResolver.resolve(segment: plan.execution, receipts: [], plan: plan, runID: "run", attemptID: "attempt"))
        plan.execution.uiProgram?.operations[0].binding = "undeclared"
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: .init()))
    }
}
