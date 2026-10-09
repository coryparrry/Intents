import XCTest
@testable import IntentsAutomationCore

final class AutomationUIOnlyPlannerTests: XCTestCase {
    private let app = AppIdentity(logicalID: "selected", bundleID: "example.UI", platform: "ios", productDigest: String(repeating: "a", count: 64))
    private let target = TargetIdentity(id: UUID().uuidString, kind: .simulator)
    private func approval() -> RunApproval { .init(runID: "approved", app: app, target: target, environmentID: "owned", effects: [.observe, .navigate], maximumActions: 30, disposable: true) }
    func testNavigationCompletionAloneNeverProducesBusinessPass() throws {
        let plan = try AutomationUIOnlyPlanner.compile(app: app, target: target, instruction: "Open tasks", endpoint: "Tasks", approval: approval(), localeIdentifier: "en_GB")
        XCTAssertTrue(plan.requirements.isEmpty); XCTAssertTrue(plan.observations.isEmpty)
        XCTAssertEqual(plan.budget.attempts, 1); XCTAssertEqual(plan.budget.controllerCalls, 12)
        XCTAssertEqual(AutomationAssessment.assess(plan: plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: []).summary, .executedUnassessed)
    }
    func testBusinessCheckIsSeparateAndRequiresExactCaseApproval() throws {
        let plan = try AutomationUIOnlyPlanner.compile(app: app, target: target, instruction: "Open tasks", endpoint: "Tasks", approvedText: "Approved input", expectedVisibleText: "Personal task complete", approval: approval(), localeIdentifier: "en_GB")
        let program = try XCTUnwrap(plan.execution.uiProgram)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(program), as: UTF8.self).contains("Personal task complete"))
        XCTAssertEqual(program.bindings, ["approvedText": "Approved input"])
        XCTAssertEqual(plan.observations[0].uiProgram?.operations.first?.kind, .observeProperty)
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval(), capabilities: .init()))
        var exact = approval(); exact.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        try PlanValidator.validate(plan, approval: exact, capabilities: .init())
        var changed = plan; changed.requirements[0].expected = .text("Changed oracle")
        XCTAssertThrowsError(try PlanValidator.validate(changed, approval: exact, capabilities: .init()))
        XCTAssertEqual(AutomationAssessment.assess(plan: plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: []).summary, .needsReview)
    }
    func testIndependentStablePropertyCanProduceAnAssessedFailure() throws {
        let plan = try AutomationUIOnlyPlanner.compile(app: app, target: target, instruction: "Set the volume", endpoint: "Volume", expectedVisibleText: "50%", observationLabel: "Volume", observationProperty: "value", approval: approval(), localeIdentifier: "en_GB")
        let observer = plan.observations[0], operation = try XCTUnwrap(observer.uiProgram?.operations.first)
        let capture = AutomationUIReadback(schemaVersion: 1, appBundleId: app.bundleID, targetId: target.id, complete: true,
            nodes: [.init(index: 0, label: "Volume", value: "40%", blocked: false, hidden: false, visible: true, disabled: false, secure: false)])
        let actual = try capture.extract(operation: operation, app: app, target: target)
        let fact = AutomationObservation(id: observer.id, app: app, target: target, environmentID: plan.environmentID,
            attemptID: "attempt", stepID: observer.id, route: .ui, proof: .visibleState, value: actual)
        let result = AutomationAssessment.assess(plan: plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: [fact])
        XCTAssertEqual(result.summary, .assertionFailed); XCTAssertTrue(result.assessed)
        XCTAssertEqual(result.failedObservations, ["business.visible-property"])
        let boolean = try AutomationUIOnlyPlanner.compile(app: app, target: target, instruction: "Select", endpoint: "Tasks", expectedVisibleText: "true", observationLabel: "Complete", observationProperty: "checked", approval: approval(), localeIdentifier: "en_GB")
        XCTAssertEqual(boolean.requirements[0].expected, .bool(true))
        XCTAssertThrowsError(try AutomationUIOnlyPlanner.compile(app: app, target: target, instruction: "Select", endpoint: "Tasks", expectedVisibleText: "yes", observationLabel: "Complete", observationProperty: "checked", approval: approval(), localeIdentifier: "en_GB"))
    }
    func testMalformedAndUnapprovedWorkflowCannotDispatch() throws {
        for endpoint in ["", String(repeating: "a", count: 1025)] {
            XCTAssertThrowsError(try AutomationUIOnlyPlanner.compile(app: app, target: target, instruction: "Open", endpoint: endpoint, approval: approval(), localeIdentifier: "en_GB"))
        }
        var denied = approval(); denied.maximumActions = 29
        XCTAssertThrowsError(try AutomationUIOnlyPlanner.compile(app: app, target: target, instruction: "Open", endpoint: "Tasks", approval: denied, localeIdentifier: "en_GB"))
        XCTAssertThrowsError(try AutomationUIOnlyPlanner.compile(app: app, target: target, instruction: "Open", endpoint: "Tasks", approval: approval(), localeIdentifier: ""))
    }
}
