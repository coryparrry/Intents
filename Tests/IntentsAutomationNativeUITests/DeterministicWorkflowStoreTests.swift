#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

final class DeterministicWorkflowStoreTests: XCTestCase {
    func testConcreteWorkflowPreservesOrderedControlsAndApprovedBinding() throws {
        let program = try AutomationNativeWorkflowSteps.program(tapControls: "id:add\nlabel:Details", textEntry: "id:title",
            approvedText: "Approved name", submitControl: "Save", endpoint: "id:task-list")
        XCTAssertEqual(program.operations.map(\.kind), [.tap, .tap, .fillBinding, .tap, .assertEndpoint])
        XCTAssertEqual(program.operations[0].locator, .init(.testId, "add"))
        XCTAssertEqual(program.operations[1].locator, .init(.label, "Details"))
        XCTAssertEqual(program.operations[2].binding, "approvedText")
        XCTAssertEqual(program.bindings, ["approvedText": "Approved name"])
        XCTAssertEqual(program.operations.last?.locator, .init(.testId, "task-list"))
        XCTAssertFalse(program.operations.contains { $0.kind == .navigateGoal })
    }
    func testReadOnlyWorkflowNeedsNoWriteControlOrText() throws {
        let program = try AutomationNativeWorkflowSteps.program(tapControls: "Tasks", textEntry: "", approvedText: "",
            submitControl: "", endpoint: "Tasks")
        XCTAssertEqual(program.operations.map(\.kind), [.tap, .assertEndpoint])
        XCTAssertTrue(program.bindings.isEmpty)
    }
    func testMissingAndOversizedControlsFailBeforeDispatch() {
        for control in ["", " ", "id:", "label:", String(repeating: "x", count: 1025)] {
            XCTAssertThrowsError(try AutomationNativeWorkflowSteps.locator(control))
        }
        XCTAssertThrowsError(try AutomationNativeWorkflowSteps.program(tapControls: "", textEntry: "", approvedText: "name",
            submitControl: "Save", endpoint: "Tasks"))
    }
}

extension InstalledUIStoreTests {
    func testPreparedWorkflowUsesConcreteStepsWithoutRuntimeEvidence() async throws {
        let (model, root, _) = try await fixture()
        XCTAssertFalse(model.canRun, "An installed app has no prepared XCUITest host")
        try selectPreparedSource(model: model, root: root)
        model.uiTapControls = "id:add"; model.uiTextEntryControl = "id:title"; model.uiSubmitControl = "Save"
        XCTAssertTrue(model.canRun)
        let request = try model.makeNativeRunRequest(runID: "concrete-workflow")
        XCTAssertFalse(try XCTUnwrap(request.plan.execution.uiProgram).operations.contains { $0.kind == .navigateGoal })
        XCTAssertEqual(request.plan.budget.controllerCalls, 1)
        let host = try AutomationXCUITestPlan.assemble(plan: request.plan, approval: request.approval,
            attemptID: "native-workflow-preflight", leaseGeneration: 1)
        XCTAssertEqual(host.steps.map(\.kind), [.launch, .tap, .clearAndType, .tap, .waitFor, .screenshot])
        XCTAssertEqual(request.plan.budget.subjectOperations, host.steps.count)
        XCTAssertEqual(request.plan.budget.uiActions, 4)
        XCTAssertNil(request.plan.provenance["ui.runtimeManifestDigest"])
        XCTAssertNil(request.plan.provenance["ui.runtimeTeamID"])
        XCTAssertNotNil(request.plan.preparedSimulatorBuildArtifacts)
    }
    func testRunningPreparedWorkflowDispatchesDriverCompatiblePlan() async throws {
        let capture = NativeWorkflowDispatchCapture()
        let executor: AutomationNativeRunExecutor = { subject, plan, approval, _, attemptID, _ in
            try await capture.validate(subject: subject, plan: plan, approval: approval, attemptID: attemptID)
            throw NativeWorkflowFixtureStop.complete
        }
        let (model, _, _) = try await fixture(executor: executor)
        model.uiTapControls = "id:add"; model.uiTextEntryControl = "id:title"; model.uiSubmitControl = "Save"
        XCTAssertTrue(model.canRun)
        model.run(); await model.task?.value
        let steps = await capture.steps
        XCTAssertEqual(steps, [.launch, .tap, .clearAndType, .tap, .waitFor, .screenshot])
        XCTAssertFalse(model.busy)
    }
    func testFreshRecordRequiresNameAndSaveControlsAndKeepsAttemptBinding() async throws {
        let (model, root, _) = try await fixture()
        try selectFreshSource(model: model, root: root)
        model.freshNameEntryControl = ""; model.freshSaveControl = ""
        XCTAssertFalse(model.canRun)
        model.freshCreateControl = "id:add"; model.freshNameEntryControl = "id:title"; model.freshSaveControl = "id:save"
        XCTAssertTrue(model.canRun)
        let request = try model.makeNativeRunRequest(runID: "concrete-fresh")
        let setup = try XCTUnwrap(request.plan.setup.first?.uiProgram)
        XCTAssertEqual(setup.operations.map(\.kind), [.tap, .fillBinding, .tap, .assertEndpoint])
        XCTAssertEqual(setup.operations[1].binding, "approvedText")
        XCTAssertEqual(request.plan.setup.first?.attemptTextBindings, ["approvedText": "Invoice"])
        XCTAssertFalse(setup.operations.contains { $0.kind == .navigateGoal })
        let host = try AutomationXCUITestPlan.assemble(plan: request.plan, approval: request.approval,
            attemptID: "native-fresh-preflight", leaseGeneration: 1)
        XCTAssertTrue(host.steps.contains { $0.kind == .checkFreshness })
        XCTAssertEqual(host.steps.filter { $0.segmentID == request.plan.execution.id }.count, 1)
        XCTAssertEqual(request.plan.budget.subjectOperations, 1)
        XCTAssertEqual(request.plan.budget.controllerCalls, 1)
        XCTAssertNil(request.plan.provenance["ui.runtimeTeamID"])
    }
}
private enum NativeWorkflowFixtureStop: Error { case complete }

private actor NativeWorkflowDispatchCapture {
    var steps: [UIHostStep.Kind] = []
    func validate(subject: AutomationApplicationSubject, plan: AutomationCase, approval: RunApproval, attemptID: String) throws {
        guard case .prepared = subject else { throw AutomationContractError.invalidIdentity }
        steps = try AutomationXCUITestPlan.assemble(plan: plan, approval: approval, attemptID: attemptID, leaseGeneration: 1).steps.map(\.kind)
    }
}
#endif
