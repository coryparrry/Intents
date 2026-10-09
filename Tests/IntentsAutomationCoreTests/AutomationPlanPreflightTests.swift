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
    func testStructuralDenialsNameTheRejectedPlanShape() throws {
        var (valid, approval) = fixture()
        approval.effects = [.observe, .navigate, .fixtureWrite]
        valid.setup = [.init(id: "seed", kind: .systemIntent, phase: .setup, operation: "seed")]
        valid.observations = [.init(id: "read", kind: .systemQuery, phase: .observe, operation: "read")]
        valid.cleanup = [.init(id: "undo", kind: .systemIntent, phase: .cleanup, operation: "undo")]
        XCTAssertNoThrow(try PlanValidator.validate(valid, approval: approval, capabilities: .init()))
        let denials: [(String, (inout AutomationCase) -> Void)] = [
            ("Duplicate segment", { $0.setup[0].id = "subject" }),
            ("Duplicate segment", { $0.cleanup[0].id = "read" }),
            ("Duplicate segment", { $0.observations.append(.init(id: "read", kind: .systemQuery, phase: .observe, operation: "again")) }),
            ("Phase mismatch", { $0.setup[0].phase = .observe }),
            ("Phase mismatch", { $0.observations[0].phase = .setup }),
            ("Phase mismatch", { $0.cleanup[0].phase = .subject }),
            ("Invalid budget", { $0.budget.attempts = 0 }),
            ("Invalid budget", { $0.budget.subjectOperations = 0 }),
            ("Invalid budget", { $0.budget.wallClockSeconds = 0 }),
            ("Invalid budget", { $0.budget.uiActions = 0 }),
            ("Invalid budget", { $0.budget.controllerCalls = -1 }),
        ]
        for (index, (reason, mutate)) in denials.enumerated() {
            var plan = valid; mutate(&plan)
            XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: .init()), "denial \(index)") {
                XCTAssertEqual($0 as? AutomationContractError, .invalidPlan(reason), "denial \(index)")
            }
        }
        var withoutController = valid; withoutController.budget.controllerCalls = 0
        XCTAssertNoThrow(try PlanValidator.validate(withoutController, approval: approval, capabilities: .init()))
    }
    func testSaveControlRequiresApprovedWritesOutsideObservers() throws {
        var (plan, approval) = fixture()
        approval.effects = [.observe, .navigate, .fixtureWrite, .externalWrite]
        var goal = AutomationNavigationGoal(id: "save", instruction: "Save the edited task", endpoint: .init(.testId, "saved"))
        goal.saveControl = .init(.label, "Save")
        var subject = AutomationSegment(id: "subject", kind: .ui, phase: .subject, operation: "save", effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
        subject.uiProgram = .init(operations: [.init(id: "save", kind: .navigateGoal, goal: goal)])
        plan.execution = subject
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: .init())) {
            XCTAssertEqual($0 as? AutomationContractError, .invalidPlan("Save control requires approved write effects"))
        }
        for write in [AutomationEffect.fixtureWrite, .externalWrite] {
            plan.execution.effects = [.observe, .navigate, write]
            XCTAssertNoThrow(try PlanValidator.validate(plan, approval: approval, capabilities: .init()))
        }
        var observer = subject; observer.id = "read"; observer.phase = .observe
        var readGoal = goal; readGoal.saveControl = nil
        observer.uiProgram = .init(operations: [.init(id: "save", kind: .navigateGoal, goal: readGoal)])
        plan.observations = [observer]
        XCTAssertNoThrow(try PlanValidator.validate(plan, approval: approval, capabilities: .init()))
        observer.uiProgram = subject.uiProgram
        plan.observations = [observer]
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: .init())) {
            guard case .invalidPlan? = $0 as? AutomationContractError else { return XCTFail("Unexpected error \($0)") }
        }
    }
    func testAssertionsNeedJustificationAndAnIndependentObservation() throws {
        var (plan, approval) = fixture()
        plan.setup = [.init(id: "seed", kind: .systemIntent, phase: .setup, operation: "seed")]
        plan.observations = [.init(id: "read", kind: .systemQuery, phase: .observe, operation: "read")]
        plan.requirements = [.init(observationID: "read", expected: .bool(true), proof: .persistedState, justification: "Approved completion requirement")]
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        XCTAssertNoThrow(try PlanValidator.validate(plan, approval: approval, capabilities: .init()))
        let denials: [(String, (inout AutomationRequirement) -> Void)] = [
            ("Unjustified assertion", { $0.justification = "" }),
            ("Unjustified assertion", { $0.justification = " \n\t" }),
            ("Assertion has no independent observation", { $0.observationID = "missing" }),
            ("Assertion has no independent observation", { $0.observationID = "seed" }),
            ("Assertion has no independent observation", { $0.observationID = "subject" }),
        ]
        for (index, (reason, mutate)) in denials.enumerated() {
            var denied = plan; mutate(&denied.requirements[0])
            var exact = approval; exact.approvedCaseDigest = try AutomationFrozenCase.planDigest(denied)
            XCTAssertThrowsError(try PlanValidator.validate(denied, approval: exact, capabilities: .init()), "denial \(index)") {
                XCTAssertEqual($0 as? AutomationContractError, .invalidPlan(reason), "denial \(index)")
            }
            XCTAssertThrowsError(try PlanValidator.validate(denied, approval: approval, capabilities: .init()), "denial \(index)") {
                XCTAssertEqual($0 as? AutomationContractError, .invalidPlan("Business assertions require approval of this exact frozen case"), "denial \(index)")
            }
        }
    }
    func testSegmentCodecRejectsDuplicateEffectsAndEncodesThemSorted() throws {
        let segment = AutomationSegment(id: "save", kind: .systemIntent, phase: .subject, operation: "save", effects: [.observe, .navigate, .fixtureWrite])
        let encoded = try JSONEncoder().encode(segment)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["effects"] as? [String], ["fixtureWrite", "navigate", "observe"])
        XCTAssertEqual(try JSONDecoder().decode(AutomationSegment.self, from: encoded), segment)
        json["effects"] = ["observe", "observe"]
        let duplicated = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try JSONDecoder().decode(AutomationSegment.self, from: duplicated)) {
            XCTAssertEqual($0 as? AutomationContractError, .invalidIdentity)
        }
    }
}
