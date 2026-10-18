import XCTest
@testable import IntentsAutomationCore
import IntentsAutomationUIHostContracts

final class AutomationUIOnlyPlannerTests: XCTestCase {
    private let app = AppIdentity(logicalID: "selected", bundleID: "example.UI", platform: "ios", productDigest: String(repeating: "a", count: 64))
    private let target = TargetIdentity(id: UUID().uuidString, kind: .simulator)
    private var reviewedProgram: AutomationUIProgram { .init(operations: [.init(id: "request", kind: .fillBinding, locator: .init(.testId, "request"), binding: "approvedText"), .init(id: "send", kind: .tap, locator: .init(.testId, "send"))], bindings: ["approvedText": "Show my completed tasks"]) }
    private func approval() -> RunApproval { .init(runID: "approved", app: app, target: target, environmentID: "owned", effects: [.observe, .navigate], maximumActions: 30, disposable: true) }
    func testNavigationCompletionAloneNeverProducesBusinessPass() throws {
        let plan = try AutomationUIOnlyPlanner.compile(app: app, target: target, program: reviewedProgram, approval: approval(), localeIdentifier: "en_GB")
        XCTAssertTrue(plan.requirements.isEmpty); XCTAssertTrue(plan.observations.isEmpty)
        XCTAssertEqual(plan.budget.attempts, 1); XCTAssertEqual(plan.budget.controllerCalls, 0)
        XCTAssertEqual(AutomationAssessment.assess(plan: plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: []).summary, .executedUnassessed)
    }
    func testUnknownCheckedValueCannotPassAnUncheckedRequirement() throws {
        let plan = try AutomationUIOnlyPlanner.compile(app: app, target: target, program: reviewedProgram,
            expectedVisibleText: "false", observationLabel: "Complete", observationProperty: "checked",
            approval: approval(), localeIdentifier: "en_GB")
        let observer = plan.observations[0]
        func assess(_ value: Bool) -> AttemptResult {
            let fact = AutomationObservation(id: observer.id, app: app, target: target,
                environmentID: plan.environmentID, attemptID: "attempt", stepID: observer.id,
                route: .ui, proof: .visibleState, value: .object(["visible-text": .bool(value)]))
            return AutomationAssessment.assess(plan: plan, attemptID: "attempt", subjectDispatched: true,
                subjectCompleted: true, observations: [fact])
        }
        XCTAssertEqual(assess(try UIHostBooleanProperty.checked(from: "0")).summary, .passed)
        XCTAssertEqual(assess(try UIHostBooleanProperty.checked(from: "1")).summary, .assertionFailed)
        let unavailable: [String?] = [nil, "", "2", "mixed", "false", "true", " 0", "0 "]
        for raw in unavailable {
            XCTAssertThrowsError(try UIHostBooleanProperty.checked(from: raw))
        }
        XCTAssertEqual(AutomationAssessment.assess(plan: plan, attemptID: "attempt", subjectDispatched: true,
            subjectCompleted: true, observations: []).summary, .needsReview)
    }
    func testHumanDescriptionChangesMetadataWhilePreservingReviewedSteps() throws {
        let plan = try AutomationUIOnlyPlanner.compile(app: app, target: target, program: reviewedProgram,
            description: "  Submit a completed-task request  ", approval: approval(), localeIdentifier: "en_GB")
        XCTAssertEqual(plan.execution.operation, "Submit a completed-task request")
        XCTAssertEqual(plan.execution.uiProgram, reviewedProgram)
        XCTAssertEqual(plan.budget.controllerCalls, 0)
        let renamed = try AutomationUIOnlyPlanner.compile(app: app, target: target, program: reviewedProgram,
            description: "Review completed tasks", approval: approval(), localeIdentifier: "en_GB")
        XCTAssertEqual(renamed.execution.uiProgram, plan.execution.uiProgram)
        XCTAssertNotEqual(try AutomationFrozenCase.planDigest(renamed), try AutomationFrozenCase.planDigest(plan))
        for invalid in ["", "  ", String(repeating: "x", count: 4097), "bad\0description"] {
            XCTAssertThrowsError(try AutomationUIOnlyPlanner.compile(app: app, target: target, program: reviewedProgram,
                description: invalid, approval: approval(), localeIdentifier: "en_GB"))
        }
    }
    func testBusinessCheckIsSeparateAndRequiresExactCaseApproval() throws {
        let plan = try AutomationUIOnlyPlanner.compile(app: app, target: target, program: reviewedProgram, expectedVisibleText: "Personal task complete", approval: approval(), localeIdentifier: "en_GB")
        let program = try XCTUnwrap(plan.execution.uiProgram)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(program), as: UTF8.self).contains("Personal task complete"))
        XCTAssertEqual(program.bindings, ["approvedText": "Show my completed tasks"])
        XCTAssertEqual(plan.observations[0].uiProgram?.operations.first?.kind, .observeProperty)
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval(), capabilities: .init()))
        var exact = approval(); exact.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        try PlanValidator.validate(plan, approval: exact, capabilities: .init())
        var changed = plan; changed.requirements[0].expected = .text("Changed oracle")
        XCTAssertThrowsError(try PlanValidator.validate(changed, approval: exact, capabilities: .init()))
        XCTAssertEqual(AutomationAssessment.assess(plan: plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: []).summary, .needsReview)
    }
    func testIndependentStablePropertyCanProduceAnAssessedFailure() throws {
        let plan = try AutomationUIOnlyPlanner.compile(app: app, target: target, program: reviewedProgram, expectedVisibleText: "50%", observationLabel: "Volume", observationProperty: "value", approval: approval(), localeIdentifier: "en_GB")
        let observer = plan.observations[0]
        let fact = AutomationObservation(id: observer.id, app: app, target: target, environmentID: plan.environmentID,
            attemptID: "attempt", stepID: observer.id, route: .ui, proof: .visibleState, value: .object(["visible-text": .text("40%")]))
        let result = AutomationAssessment.assess(plan: plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: [fact])
        XCTAssertEqual(result.summary, .assertionFailed); XCTAssertTrue(result.assessed)
        XCTAssertEqual(result.failedObservations, ["business.visible-property"])
        let boolean = try AutomationUIOnlyPlanner.compile(app: app, target: target, program: reviewedProgram, expectedVisibleText: "true", observationLabel: "Complete", observationProperty: "checked", approval: approval(), localeIdentifier: "en_GB")
        XCTAssertEqual(boolean.requirements[0].expected, .object(["visible-text": .bool(true)]))
        XCTAssertThrowsError(try AutomationUIOnlyPlanner.compile(app: app, target: target, program: reviewedProgram, expectedVisibleText: "yes", observationLabel: "Complete", observationProperty: "checked", approval: approval(), localeIdentifier: "en_GB"))
    }
    func testVerifiedPropertyOutputMatchesTheIndependentCheck() throws {
        let properties: [(String, String, AutomationValue, AutomationValue)] = [
            ("text", "Correct", .text("Correct"), .text("Wrong")),
            ("value", "Correct", .text("Correct"), .text("Wrong")),
            ("checked", "true", .bool(true), .bool(false)),
            ("selected", "false", .bool(false), .bool(true))
        ]
        for (subject, selectedTarget) in [(app, target)] {
            let approved = RunApproval(runID: "approved", app: subject, target: selectedTarget, environmentID: "owned",
                effects: [.observe, .navigate], maximumActions: 30, disposable: true)
            for (property, expected, correct, wrong) in properties {
                let plan = try AutomationUIOnlyPlanner.compile(app: subject, target: selectedTarget, program: reviewedProgram,
                    expectedVisibleText: expected, observationLabel: "Result",
                    observationProperty: property, approval: approved, localeIdentifier: "en_GB")
                let observer = plan.observations[0]
                let operation = try XCTUnwrap(observer.uiProgram?.operations.first)
                func assess(_ value: AutomationValue) -> AttemptResult {
                    let fact = AutomationObservation(id: observer.id, app: subject, target: selectedTarget,
                        environmentID: plan.environmentID, attemptID: "attempt", stepID: observer.id,
                        route: .ui, proof: .visibleState, value: value)
                    return AutomationAssessment.assess(plan: plan, attemptID: "attempt", subjectDispatched: true,
                        subjectCompleted: true, observations: [fact])
                }
                XCTAssertEqual(assess(.object([operation.id: correct])).summary, .passed)
                XCTAssertEqual(assess(.object([operation.id: wrong])).summary, .assertionFailed)
                XCTAssertEqual(assess(.object(["different-operation": correct])).summary, .assertionFailed)
                XCTAssertEqual(assess(.object([operation.id: correct, "extra": correct])).summary, .assertionFailed)
                XCTAssertEqual(assess(correct).summary, .assertionFailed)
                XCTAssertEqual(assess(.object([:])).summary, .assertionFailed)
            }
        }
    }
    func testMalformedAndUnapprovedWorkflowCannotDispatch() throws {
        var malformed = reviewedProgram
        malformed.bindings.removeAll()
        XCTAssertThrowsError(try AutomationUIOnlyPlanner.compile(app: app, target: target, program: malformed,
            approval: approval(), localeIdentifier: "en_GB"))
        var denied = approval(); denied.maximumActions = 29
        XCTAssertThrowsError(try AutomationUIOnlyPlanner.compile(app: app, target: target, program: reviewedProgram, approval: denied, localeIdentifier: "en_GB"))
        XCTAssertThrowsError(try AutomationUIOnlyPlanner.compile(app: app, target: target, program: reviewedProgram, approval: approval(), localeIdentifier: ""))
    }

    func testNativeMacUIRequiresAnAssociatedHostWorkflow() throws {
        var mac = app; mac.platform = "macos"; mac.productDigestVersion = 2
        mac.canonicalBundlePath = "/private/tmp/Qualification.app"
        let native = TargetIdentity(id: "host-macos-local", kind: .nativeMac, loginSession: "qualified-session")
        let approved = RunApproval(runID: "approved", app: mac, target: native, environmentID: "owned",
            effects: [.observe, .navigate], maximumActions: 30, disposable: true)
        XCTAssertThrowsError(try AutomationUIOnlyPlanner.compile(app: mac, target: native, program: reviewedProgram,
            approval: approved, localeIdentifier: "en_GB"))
    }
}
