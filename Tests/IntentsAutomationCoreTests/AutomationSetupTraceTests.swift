import XCTest
@testable import IntentsAutomationCore

final class AutomationSetupTraceTests: XCTestCase {
    private let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "create", leaseGeneration: 1)
    private let goal = AutomationNavigationGoal(id: "create", instruction: "Create", endpoint: .init(.testId, "done"))
    private func request() -> AutomationControllerRequest {
        .init(goalId: "create", revision: "1", nodes: [.init(id: "n1", role: "textfield", name: "Title", testId: "task.title", text: nil, value: nil, editable: true, visible: true, disabled: false, secure: false)], truncated: false, omittedNodes: 0, verbs: ["fill", "tap", "scroll"], recentActions: [], remainingActions: 30, remainingMs: 120_000)
    }
    func testCompleteConsumedTraceRetainsOnlyTypedLocatorAndBinding() {
        var trace = AutomationSetupTrace()
        trace.prepare(.init(kind: "fill", node: "n1", textBinding: "approved"), request: request())
        XCTAssertNil(trace.capture(scope: scope, goal: goal))
        trace.consume(); XCTAssertNil(trace.capture(scope: scope, goal: goal))
        trace.prepare(.init(kind: "finish"), request: request())
        XCTAssertEqual(trace.capture(scope: scope, goal: goal)?.operations, [
            .init(id: "learned.0", kind: .fillBinding, locator: .init(.testId, "task.title"), binding: "approved"),
            .init(id: "learned.endpoint", kind: .assertEndpoint, locator: goal.endpoint)])
        trace.prepare(.init(kind: "tap", node: "n1"), request: request())
        XCTAssertNil(trace.capture(scope: scope, goal: goal))
    }
    func testEveryIncompleteOrUnstableStepInvalidatesEntireTrace() {
        for variant in 0..<6 {
            var trace = AutomationSetupTrace(), invalid = request()
            trace.prepare(.init(kind: "fill", node: "n1", textBinding: "approved"), request: request()); trace.consume()
            switch variant {
            case 0: invalid.truncated = true
            case 1: invalid.omittedNodes = 1
            case 2: invalid.nodes[0].testId = nil
            case 3: var duplicate = invalid.nodes[0]; duplicate.id = "other"; invalid.nodes.append(duplicate)
            case 4: invalid.nodes[0].secure = true
            default: invalid.nodes[0].visible = false
            }
            trace.prepare(.init(kind: "fill", node: "n1", textBinding: "approved"), request: invalid)
            trace.consume(); trace.prepare(.init(kind: "finish"), request: request())
            XCTAssertNil(trace.capture(scope: scope, goal: goal), "variant \(variant)")
        }
    }
    func testUniqueButtonLabelFallbackAndEndpointCountLimit() {
        var observed = request(); observed.nodes[0].testId = nil; observed.nodes[0].role = "button"; observed.nodes[0].name = "Add task"
        var trace = AutomationSetupTrace()
        trace.prepare(.init(kind: "tap", node: "n1"), request: observed); trace.consume()
        trace.prepare(.init(kind: "finish"), request: observed)
        XCTAssertEqual(trace.capture(scope: scope, goal: goal)?.operations.first?.locator, .init(.label, "Add task", role: .button))
        var bounded = AutomationSetupTrace()
        for _ in 0..<29 { bounded.prepare(.init(kind: "scroll", direction: "down"), request: request()); bounded.consume() }
        bounded.prepare(.init(kind: "finish"), request: request())
        XCTAssertEqual(bounded.capture(scope: scope, goal: goal)?.operations.count, 30)
        var tooLong = AutomationSetupTrace()
        for _ in 0..<30 { tooLong.prepare(.init(kind: "scroll", direction: "down"), request: request()); tooLong.consume() }
        tooLong.prepare(.init(kind: "finish"), request: request()); XCTAssertNil(tooLong.capture(scope: scope, goal: goal))
    }
}
