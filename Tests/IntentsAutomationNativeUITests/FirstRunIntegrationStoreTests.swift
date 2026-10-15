#if os(macOS)
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

extension InstalledUIStoreTests {
    func testSavedSystemActionWithUIReadbackUsesPreparedHostEvidence() async throws {
        let runtime = RuntimeIdentity()
        let (model, root, _) = try await fixture(runtime: runtime)
        try selectPreparedSource(model: model, root: root)
        var prepared = try XCTUnwrap(model.prepared)
        prepared.catalog.systemActions = [.init(id: "ObserveAction", typeName: "ObserveAction", title: "Observe action",
            parameters: [], parametersComplete: true, compiled: true, registered: false, executed: false, resultFamily: "noValue")]
        model.prepared = prepared; model.catalog = prepared.catalog
        model.firstRunIncludesActions = true; model.effectChoice = "navigation"; model.firstRunEffectsConfirmed = true
        var plan = try XCTUnwrap(model.reviewFirstChecks().requests.first { $0.plan.execution.kind == .systemIntent }?.plan)
        var observer = AutomationSegment(id: "independent-state", kind: .ui, phase: .observe, operation: "Read the result",
            effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
        observer.uiProgram = .init(operations: [.init(id: "result", kind: .observeProperty, locator: .init(.label, "Result"), property: "value")])
        plan.observations = [observer]
        plan.requirements = [.init(observationID: observer.id, expected: .object(["result": .text("Correct")]), proof: .visibleState,
            justification: "Approved independent result", checkID: "business.result")]
        plan.budget.uiActions = 4
        plan.provenance["ui.locale"] = Locale.current.identifier
        plan.provenance["ui.backend"] = "xcuitest"
        model.savedCases = [try AutomationFrozenCase(plan: plan)]
        let request = try XCTUnwrap(model.reviewFirstChecks().requests.first { !$0.plan.requirements.isEmpty })
        XCTAssertEqual(request.plan.execution.kind, .systemIntent)
        XCTAssertEqual(request.plan.requirements, plan.requirements)
        XCTAssertNil(request.plan.provenance["ui.runtimeTeamID"])
        XCTAssertNil(request.plan.provenance["ui.runtimeManifestDigest"])
        XCTAssertEqual(request.plan.preparedSimulatorBuildArtifacts, try .init(prepared: prepared))
        for key in ["ui.preparedHostDigest", "ui.preparedXctestrunDigest", "ui.preparedCatalogDigest", "ui.hostTemplateDigest"] {
            XCTAssertNil(request.plan.provenance[key])
        }
        let host = try AutomationXCUITestPlan.assemble(plan: request.plan, approval: request.approval,
            attemptID: "saved-action-readback", leaseGeneration: 1)
        XCTAssertEqual(host.steps.filter { $0.segmentID == request.plan.execution.id }.count, 1)
        XCTAssertEqual(request.plan.budget.controllerCalls, 0)
        XCTAssertEqual(host.steps.last?.kind, .screenshot)
    }

    func testFirstCheckReviewUsesApprovedInputsAndRejectsChangedValuesBeforeDispatch() async throws {
        let (model, root, _) = try await fixture()
        try selectPreparedSource(model: model, root: root)
        var prepared = try XCTUnwrap(model.prepared)
        prepared.catalog.systemActions = [.init(id: "Required", typeName: "Required", title: "Required",
            parameters: [.init(name: "text", family: "text", optional: false)], parametersComplete: true,
            compiled: true, registered: false, executed: false, resultFamily: "noValue")]
        model.prepared = prepared; model.catalog = prepared.catalog
        model.firstRunIncludesActions = true; model.effectChoice = "navigation"; model.firstRunEffectsConfirmed = true
        model.firstRunInputs = ["Required": ["text": "approved example"]]
        let review = try model.reviewFirstChecks()
        XCTAssertEqual(review.requests.count, 2)
        XCTAssertEqual(review.requests.last?.plan.execution.inputs["text"], .text("approved example"))
        model.firstRunInputs["Required"]?["text"] = "changed example"
        model.runFirstChecks(review)
        XCTAssertFalse(model.busy); XCTAssertTrue(model.firstRunReports.isEmpty)
        XCTAssertNotNil(model.message)
    }

    func testSelectingAnAppClearsFirstCheckValuesAndPendingReview() async throws {
        let (model, _, app) = try await fixture()
        model.firstRunInputReviewID = "old-review"
        model.firstRunInputs = ["Old": ["text": "old value"]]
        model.firstRunEntityQueryTexts = ["Old": ["entity": "old search"]]
        model.firstRunSelectedEntityIDs = ["Old": ["entity": "old selection"]]
        model.select(app); await model.task?.value
        XCTAssertNil(model.firstRunInputReviewID)
        XCTAssertTrue(model.firstRunInputs.isEmpty)
        XCTAssertTrue(model.firstRunEntityQueryTexts.isEmpty)
        XCTAssertTrue(model.firstRunSelectedEntityIDs.isEmpty)
    }
}
#endif
