#if canImport(FoundationModels)
import XCTest
import FoundationModels
@testable import IntentsAutomationCore

final class AutomationControllerLiveModelTests: XCTestCase {
    func testLocalModelAdvancesVisibleButtonGoalBeforeFinishing() async throws {
        guard ProcessInfo.processInfo.environment["INTENTS_RUN_FOUNDATION_CONTROLLER"] == "1" else {
            throw XCTSkip("Opt in to actual local model inference with INTENTS_RUN_FOUNDATION_CONTROLLER=1")
        }
        guard SystemLanguageModel.default.availability == .available else { throw XCTSkip("Local system model unavailable") }
        let goal = AutomationNavigationGoal(id: "navigate", instruction: "Click Run check and finish when Check complete appears",
            endpoint: .init(.label, "Check complete"))
        var request = AutomationControllerRequest(goalId: goal.id, revision: "fixture-before", nodes: [
            .init(id: "run", role: "button", name: "Run check", testId: "qualification.run", editable: false, visible: true, disabled: false, secure: false),
            .init(id: "verify", role: "button", name: "Verify credential", editable: false, visible: true, disabled: false, secure: false),
            .init(id: "ready", role: "text", name: "Ready", value: "Ready", editable: false, visible: true, disabled: false, secure: false),
            .init(id: "result", role: "text", name: "Result", value: "Pending", editable: false, visible: true, disabled: false, secure: false),
            .init(id: "secure", role: "textbox", editable: false, visible: true, disabled: false, secure: true)
        ], truncated: false, omittedNodes: 0, verbs: ["tap", "scroll"], recentActions: [], remainingActions: 30, remainingMs: 120000)
        let controller = AutomationFoundationController()
        for _ in 0..<3 {
            let decision = try await controller.decide(goal: goal, request: request, bindings: [:])
            XCTAssertEqual(decision.kind, "tap"); XCTAssertEqual(decision.node, "run")
        }
        request.nodes[2].name = "Check complete"; request.nodes[2].value = "Check complete"
        request.recentActions = [#"{"decision":{"kind":"tap","node":"run"}}"#]
        request.approvedNavigationActions = 1
        let completed = try await controller.decide(goal: goal, request: request, bindings: [:])
        XCTAssertEqual(completed.kind, "finish")
    }
}
#endif
