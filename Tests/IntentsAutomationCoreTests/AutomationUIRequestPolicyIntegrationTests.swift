import XCTest
@testable import IntentsAutomationCore

final class AutomationUIRequestPolicyIntegrationTests: XCTestCase, @unchecked Sendable {
    func testReviewedSearchBudgetCanActivateFillSubmitAndFinishThroughActualAuthority() async throws {
        let app = AppIdentity(logicalID: "local-ai", bundleID: "example.LocalAI", platform: "ios")
        let target = TargetIdentity(id: "policy-integration", kind: .simulator)
        let approval = RunApproval(runID: "search", app: app, target: target, environmentID: "disposable",
            effects: [.observe, .navigate, .fixtureWrite], maximumActions: 30, disposable: true)
        let leases = AutomationDeviceLeaseManager(), lease = try await leases.acquire(runID: approval.runID, target: target, control: .ui)
        let scope = AutomationScope(runID: approval.runID, attemptID: "attempt", segmentID: "subject", leaseGeneration: lease.generation)
        var goal = AutomationNavigationGoal(id: "request", instruction: "Submit the frozen request", endpoint: .init(.label, "Response"),
            minimumBindingUses: ["approvedText": 1], allowedFillBindings: ["approvedText"])
        goal.requestInputControl = .init(.label, "Prompt"); goal.saveControl = .init(.label, "Send")
        var segment = AutomationSegment(id: "subject", kind: .ui, phase: .subject, operation: goal.instruction,
            effects: approval.effects, lifecycle: .persistedStateAcrossSegments)
        segment.uiProgram = .init(operations: [.init(id: goal.id, kind: .navigateGoal, goal: goal)], bindings: ["approvedText": "List completed tasks"])
        let oldBudget = try AutomationCampaignBudget(limits: .firstCampaign)
        let oldAuthority = AutomationRunAuthority(approval: approval, leases: leases, campaignBudget: oldBudget)
        do {
            try await oldAuthority.approve(scope: scope, lease: lease, segment: segment, actions: [.activate], maximumControllerCalls: 12)
            XCTFail("Old 20-operation cap incorrectly covered 25 reserved readbacks")
        } catch { XCTAssertEqual(error as? AutomationCampaignBudgetError, .exhausted("subject operations")) }
        let budget = try AutomationCampaignBudget(limits: .firstUIFailureSearch)
        try await budget.reserveAttempt(id: scope.attemptId)
        let authority = AutomationRunAuthority(approval: approval, leases: leases, controller: RequestPolicyController(), campaignBudget: budget)
        try await authority.approve(scope: scope, lease: lease, segment: segment, actions: [.activate], maximumControllerCalls: 12)
        var activation = fields(scope)
        activation["effect"] = .string("activate")
        activation["target"] = .object(["id": .string(target.id), "platform": .string("ios"), "kind": .string("simulator"),
            "bundleId": .string(app.bundleID), "bundlePath": .null, "loginSession": .null])
        let activated = await authority.review(method: "policy.reviewAction", params: .object(activation))
        XCTAssertEqual(activated.object?["allowed"], .bool(true))
        var request = AutomationControllerRequest(goalId: goal.id, revision: "1", nodes: [
            .init(id: "input", role: "textfield", name: "Prompt", text: nil, value: "", editable: true, visible: true, disabled: false, secure: false),
            .init(id: "send", role: "button", name: "Send", text: nil, value: nil, editable: false, visible: true, disabled: false, secure: false),
            .init(id: "clear", role: "button", name: "New conversation", text: nil, value: nil, editable: false, visible: true, disabled: false, secure: false),
            .init(id: "response", role: "text", name: "Response", text: nil, value: nil, editable: false, visible: true, disabled: false, secure: false)],
            truncated: false, omittedNodes: 0, verbs: ["tap", "fill", "scroll"], recentActions: [], remainingActions: 30, remainingMs: 120_000)
        var decisionFields = fields(scope)
        decisionFields["request"] = try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(request))
        let fill = await authority.review(method: "controller.decide", params: .object(decisionFields))
        XCTAssertEqual(fill.object?["kind"], .string("fill"))
        var policy = fields(scope); policy["controllerNode"] = .string("input")
        policy["action"] = .object(["kind": .string("fill"), "value": .string("Changed request"), "sensitive": .bool(false)])
        let changed = await authority.review(method: "policy.reviewAction", params: .object(policy))
        XCTAssertEqual(changed.object?["allowed"], .bool(false))
        policy["action"] = .object(["kind": .string("fill"), "value": .string("List completed tasks"), "sensitive": .bool(false)])
        let approvedFill = await authority.review(method: "policy.reviewAction", params: .object(policy))
        XCTAssertEqual(approvedFill.object?["allowed"], .bool(true))
        request.nodes[0].value = "List completed tasks"
        request.completedBindingUses = ["approvedText": 1]
        decisionFields["request"] = try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(request))
        let tap = await authority.review(method: "controller.decide", params: .object(decisionFields))
        XCTAssertEqual(tap.object?["kind"], .string("tap"))
        policy["controllerNode"] = .string("send"); policy["action"] = .object(["kind": .string("tap")])
        let submitted = await authority.review(method: "policy.reviewAction", params: .object(policy))
        XCTAssertEqual(submitted.object?["allowed"], .bool(true))
        request.approvedSaveTap = true
        decisionFields["request"] = try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(request))
        let finished = await authority.review(method: "controller.decide", params: .object(decisionFields))
        XCTAssertEqual(finished.object?["kind"], .string("finish"))
        let usage = await budget.snapshot()
        XCTAssertEqual(usage.reservedSubjectOperations, 28); XCTAssertEqual(usage.reservedUIActions, 3)
        XCTAssertEqual(usage.controllerCalls, 3)
        try await authority.revoke(scope: scope)
        try await leases.release(lease, commandsDrained: true, ownedRunnerTerminated: true)
    }
    func testAuthorityRejectsSubmitBeforeFillAndUnrelatedOrAmbiguousInput() async throws {
        for scenario in 0..<3 {
            let first: AutomationControllerDecision = scenario == 0 ? .init(kind: "tap", node: "send") : .init(kind: "fill", node: scenario == 1 ? "other" : "input", textBinding: "approvedText")
            let h = try await harness(decisions: [first])
            let reply = try await decide(h, duplicateInput: scenario == 2)
            XCTAssertEqual(reply.object?["kind"], .string("cannotProceed"))
            let usage = await h.budget.snapshot(); XCTAssertEqual(usage.reservedUIActions, 1)
            try await h.authority.revoke(scope: h.scope); try await h.leases.release(h.lease, commandsDrained: true, ownedRunnerTerminated: true)
        }
    }
    func testMissingFillAcknowledgementPoisonsRequestAndCannotBeRetriedWithLateAcknowledgement() async throws {
        let h = try await harness(decisions: [.init(kind: "fill", node: "input", textBinding: "approvedText"), .init(kind: "tap", node: "send")])
        let fill = try await decide(h); XCTAssertEqual(fill.object?["kind"], .string("fill"))
        let allowed = await perform(h, node: "input", fill: "List completed tasks"); XCTAssertEqual(allowed.object?["allowed"], .bool(true))
        let noAck = try await decide(h); XCTAssertEqual(noAck.object?["kind"], .string("cannotProceed"))
        let lateAck = try await decide(h, completed: ["approvedText": 1]); XCTAssertEqual(lateAck.object?["kind"], .string("cannotProceed"))
        let usage = await h.budget.snapshot(); XCTAssertEqual(usage.reservedUIActions, 2)
        try await h.authority.revoke(scope: h.scope); try await h.leases.release(h.lease, commandsDrained: true, ownedRunnerTerminated: true)
    }
    func testAcknowledgedRequestCannotBeRefilledAndCommittedRequestCannotSubmitTwice() async throws {
        for secondSubmit in [false, true] {
            let decisions: [AutomationControllerDecision] = secondSubmit ? [.init(kind: "fill", node: "input", textBinding: "approvedText"), .init(kind: "tap", node: "send"), .init(kind: "tap", node: "send")] : [.init(kind: "fill", node: "input", textBinding: "approvedText"), .init(kind: "fill", node: "input", textBinding: "approvedText")]
            let h = try await harness(decisions: decisions)
            _ = try await decide(h); _ = await perform(h, node: "input", fill: "List completed tasks")
            let next = try await decide(h, completed: ["approvedText": 1])
            if secondSubmit {
                XCTAssertEqual(next.object?["kind"], .string("tap")); _ = await perform(h, node: "send")
                let repeatSubmit = try await decide(h, completed: ["approvedText": 1], submitted: true)
                XCTAssertEqual(repeatSubmit.object?["kind"], .string("cannotProceed"))
            } else { XCTAssertEqual(next.object?["kind"], .string("cannotProceed")) }
            let usage = await h.budget.snapshot(); XCTAssertEqual(usage.reservedUIActions, secondSubmit ? 3 : 2)
            try await h.authority.revoke(scope: h.scope); try await h.leases.release(h.lease, commandsDrained: true, ownedRunnerTerminated: true)
        }
    }
    func testSubmitRequiresCurrentExactInputValueAndNoInterleavedMutation() async throws {
        for scenario in 0..<3 {
            let h = try await harness(decisions: [.init(kind: "fill", node: "input", textBinding: "approvedText"), .init(kind: "tap", node: scenario == 0 ? "clear" : "send")])
            _ = try await decide(h); _ = await perform(h, node: "input", fill: "List completed tasks")
            let reply = try await decide(h, completed: ["approvedText": 1], inputValue: scenario == 2 ? nil : scenario == 1 ? "Other request" : "List completed tasks")
            XCTAssertEqual(reply.object?["kind"], .string("cannotProceed"))
            let usage = await h.budget.snapshot(); XCTAssertEqual(usage.reservedUIActions, 2)
            try await h.authority.revoke(scope: h.scope); try await h.leases.release(h.lease, commandsDrained: true, ownedRunnerTerminated: true)
        }
    }
    func testSubmitMatcherRequiresCanonicalButtonAndDoesNotInferUnknownNativeRoles() {
        var goal = AutomationNavigationGoal(id: "request", instruction: "Submit", endpoint: .init(.label, "Response"))
        goal.saveControl = .init(.label, "Send")
        for role in ["button", "AXButton", "checkbox", "AXCheckBox", "CustomButton"] {
            let node = AutomationControllerRequest.Node(id: "send", role: role, name: "Send", text: nil, value: nil, editable: false, visible: true, disabled: false, secure: false)
            XCTAssertEqual(goal.matchesSaveControl(node), role == "button")
        }
    }
    private struct Harness {
        let authority: AutomationRunAuthority, scope: AutomationScope, budget: AutomationCampaignBudget, leases: AutomationDeviceLeaseManager, lease: AutomationDeviceLeaseManager.Lease
    }
    private func harness(decisions: [AutomationControllerDecision]) async throws -> Harness {
        let app = AppIdentity(logicalID: "local-ai", bundleID: "example.LocalAI", platform: "ios"), target = TargetIdentity(id: "policy-integration", kind: .simulator)
        let approval = RunApproval(runID: "search", app: app, target: target, environmentID: "disposable", effects: [.observe, .navigate, .fixtureWrite], maximumActions: 30, disposable: true)
        let leases = AutomationDeviceLeaseManager(), lease = try await leases.acquire(runID: approval.runID, target: target, control: .ui)
        let scope = AutomationScope(runID: approval.runID, attemptID: "attempt", segmentID: "subject", leaseGeneration: lease.generation)
        let budget = try AutomationCampaignBudget(limits: .firstUIFailureSearch); try await budget.reserveAttempt(id: scope.attemptId)
        let authority = AutomationRunAuthority(approval: approval, leases: leases, controller: ScriptedRequestPolicyController(decisions: decisions), campaignBudget: budget)
        var goal = AutomationNavigationGoal(id: "request", instruction: "Submit the frozen request", endpoint: .init(.label, "Response"), minimumBindingUses: ["approvedText": 1], allowedFillBindings: ["approvedText"])
        goal.requestInputControl = .init(.label, "Prompt"); goal.saveControl = .init(.label, "Send")
        var segment = AutomationSegment(id: scope.segmentId, kind: .ui, phase: .subject, operation: goal.instruction, effects: approval.effects, lifecycle: .persistedStateAcrossSegments)
        segment.uiProgram = .init(operations: [.init(id: goal.id, kind: .navigateGoal, goal: goal)], bindings: ["approvedText": "List completed tasks"])
        try await authority.approve(scope: scope, lease: lease, segment: segment, actions: [.activate], maximumControllerCalls: 12)
        var activation = fields(scope); activation["effect"] = .string("activate")
        activation["target"] = .object(["id": .string(target.id), "platform": .string("ios"), "kind": .string("simulator"), "bundleId": .string(app.bundleID), "bundlePath": .null, "loginSession": .null])
        let activated = await authority.review(method: "policy.reviewAction", params: .object(activation)); XCTAssertEqual(activated.object?["allowed"], .bool(true))
        return .init(authority: authority, scope: scope, budget: budget, leases: leases, lease: lease)
    }
    private func decide(_ h: Harness, completed: [String: Int]? = nil, submitted: Bool = false, duplicateInput: Bool = false, inputValue: String? = "List completed tasks") async throws -> AutomationJSON {
        var request = AutomationControllerRequest(goalId: "request", revision: "1", nodes: [
            .init(id: "input", role: "textfield", name: "Prompt", text: nil, value: completed == nil ? "" : inputValue, editable: true, visible: true, disabled: false, secure: false),
            .init(id: "other", role: "textfield", name: duplicateInput ? "Prompt" : "Search", text: nil, value: nil, editable: true, visible: true, disabled: false, secure: false),
            .init(id: "send", role: "button", name: "Send", text: nil, value: nil, editable: false, visible: true, disabled: false, secure: false),
            .init(id: "clear", role: "button", name: "New conversation", text: nil, value: nil, editable: false, visible: true, disabled: false, secure: false),
            .init(id: "response", role: "text", name: "Response", text: nil, value: nil, editable: false, visible: true, disabled: false, secure: false)],
            truncated: false, omittedNodes: 0, verbs: ["tap", "fill", "scroll"], recentActions: [], remainingActions: 30, remainingMs: 120_000)
        request.completedBindingUses = completed; request.approvedSaveTap = submitted
        var data = fields(h.scope); data["request"] = try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(request))
        return await h.authority.review(method: "controller.decide", params: .object(data))
    }
    private func perform(_ h: Harness, node: String, fill: String? = nil) async -> AutomationJSON {
        var data = fields(h.scope); data["controllerNode"] = .string(node)
        data["action"] = fill.map { AutomationJSON.object(["kind": .string("fill"), "value": .string($0), "sensitive": .bool(false)]) } ?? .object(["kind": .string("tap")])
        return await h.authority.review(method: "policy.reviewAction", params: .object(data))
    }
    private func fields(_ scope: AutomationScope) -> [String: AutomationJSON] {
        ["protocolVersion": .number(1), "runId": .string(scope.runId), "attemptId": .string(scope.attemptId),
         "segmentId": .string(scope.segmentId), "leaseGeneration": .number(Double(scope.leaseGeneration))]
    }
}

private actor RequestPolicyController: AutomationControllerDecisionProvider {
    private var call = 0
    func decide(goal: AutomationNavigationGoal, request: AutomationControllerRequest, bindings: [String: String]) -> AutomationControllerDecision {
        call += 1
        return call == 1 ? .init(kind: "fill", node: "input", textBinding: "approvedText") : call == 2 ? .init(kind: "tap", node: "send") : .init(kind: "finish")
    }
}

private actor ScriptedRequestPolicyController: AutomationControllerDecisionProvider {
    private let decisions: [AutomationControllerDecision]
    private var index = 0
    init(decisions: [AutomationControllerDecision]) { self.decisions = decisions }
    func decide(goal: AutomationNavigationGoal, request: AutomationControllerRequest, bindings: [String: String]) -> AutomationControllerDecision {
        guard index < decisions.count else { return .init(kind: "cannotProceed", reason: "noSafeAction") }
        defer { index += 1 }; return decisions[index]
    }
}
