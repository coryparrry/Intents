import XCTest
@testable import IntentsAutomationCore

final class AutomationControllerTests: XCTestCase, @unchecked Sendable {
    private let app = AppIdentity(logicalID: "app", bundleID: "example.App", platform: "ios")
    private let target = TargetIdentity(id: "unit-policy-target", kind: .simulator)
    private func request() -> AutomationControllerRequest {
        .init(goalId: "subject", revision: "1", nodes: [.init(id: "n1", role: "textfield", name: "Input", text: nil, value: nil, editable: true, visible: true, disabled: false, secure: false)],
              truncated: false, omittedNodes: 0, verbs: ["tap", "fill", "scroll"], recentActions: [], remainingActions: 30, remainingMs: 120_000)
    }
    private func grant(provider: any AutomationControllerDecisionProvider, phase: AutomationSegment.Phase = .subject, writes: Bool = true, artifacts: AutomationArtifactRegistry? = nil, minimumBindingUses: [String: Int]? = nil, maximumControllerCalls: Int = 1, allowedFillBindings: [String]? = nil, campaignBudget: AutomationCampaignBudget? = nil, saveControl: AutomationUIProgram.Locator? = nil, now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) async throws -> (AutomationRunAuthority, AutomationScope) {
        let approval = RunApproval(runID: "run", app: app, target: target, environmentID: "unit", effects: [.observe, .navigate, .fixtureWrite], maximumActions: 4, disposable: true)
        let leases = AutomationDeviceLeaseManager(), lease = try await leases.acquire(runID: "run", target: target, control: .ui)
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: lease.generation)
        let authority = AutomationRunAuthority(approval: approval, leases: leases, controller: provider, artifacts: artifacts, campaignBudget: campaignBudget, now: now)
        var segment = AutomationSegment(id: "subject", kind: .ui, phase: phase, operation: "navigate", effects: writes ? [.navigate, .fixtureWrite] : [.navigate], lifecycle: .persistedStateAcrossSegments)
        var goal = AutomationNavigationGoal(id: "subject", instruction: "Open the test form", endpoint: .init(.testId, "form"), minimumBindingUses: minimumBindingUses, allowedFillBindings: allowedFillBindings)
        goal.saveControl = saveControl
        segment.uiProgram = .init(operations: [.init(id: "subject", kind: .navigateGoal, goal: goal)], bindings: phase == .observe ? [:] : ["approved": "test input", "context": "Work"])
        try await authority.approve(scope: scope, lease: lease, segment: segment, actions: [.activate], maximumControllerCalls: maximumControllerCalls, maximumUIActions: 4)
        var activation = fields(scope)
        activation["effect"] = .string("activate")
        activation["target"] = .object(["id": .string(target.id), "platform": .string("ios"), "kind": .string("simulator"), "bundleId": .string(app.bundleID), "bundlePath": .null, "loginSession": .null])
        let approved = await authority.review(method: "policy.reviewAction", params: .object(activation))
        XCTAssertEqual(approved, .object(["allowed": .bool(true)]))
        return (authority, scope)
    }
    private func fields(_ scope: AutomationScope) -> [String: AutomationJSON] {
        ["protocolVersion": .number(1), "runId": .string(scope.runId), "attemptId": .string(scope.attemptId), "segmentId": .string(scope.segmentId), "leaseGeneration": .number(Double(scope.leaseGeneration))]
    }
    private func decisionFields(_ scope: AutomationScope, _ request: AutomationControllerRequest) throws -> AutomationJSON {
        var fields = fields(scope)
        fields["request"] = try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(request))
        return .object(fields)
    }
    func testSetupCaptureRequiresExactConsumptionAndFinishCannotIssueMoreChoices() async throws {
        let provider = InputProgressNavigationProvider()
        let (authority, scope) = try await grant(provider: provider, phase: .setup, maximumControllerCalls: 3)
        var observed = request(); observed.nodes[0].testId = "task.title"
        let decision = await authority.review(method: "controller.decide", params: try decisionFields(scope, observed))
        XCTAssertEqual(decision.object?["kind"], .string("fill"))
        let pending = await authority.capturedSetup(scope: scope); XCTAssertNil(pending)
        var action = fields(scope); action["controllerNode"] = .string("n1")
        action["action"] = .object(["kind": .string("fill"), "value": .string("test input"), "sensitive": .bool(false)])
        let allowed = await authority.review(method: "policy.reviewAction", params: .object(action))
        XCTAssertEqual(allowed.object?["allowed"], .bool(true))
        let finish = await authority.review(method: "controller.decide", params: try decisionFields(scope, observed))
        XCTAssertEqual(finish.object?["kind"], .string("finish"))
        let captured = await authority.capturedSetup(scope: scope); XCTAssertEqual(captured?.operations.count, 2)
        let extra = await authority.review(method: "controller.decide", params: try decisionFields(scope, observed))
        XCTAssertEqual(extra.object?["kind"], .string("cannotProceed"))
        let calls = await provider.progress; XCTAssertEqual(calls, [0, 1])
    }
    func testFinishIsTerminalEvenForAnUnlearnableSetupObservation() async throws {
        let provider = FixedNavigationProvider(.init(kind: "finish"))
        let (authority, scope) = try await grant(provider: provider, phase: .setup, maximumControllerCalls: 3)
        var observed = request(); observed.truncated = true
        let finish = await authority.review(method: "controller.decide", params: try decisionFields(scope, observed))
        XCTAssertEqual(finish.object?["kind"], .string("finish"))
        let extra = await authority.review(method: "controller.decide", params: try decisionFields(scope, observed))
        XCTAssertEqual(extra.object?["kind"], .string("cannotProceed"))
        let captured = await authority.capturedSetup(scope: scope); XCTAssertNil(captured)
        let calls = await provider.calls; XCTAssertEqual(calls, 1)
    }
    func testFrozenFillWhitelistRejectsContextDecisionAndMalformedDeclarations() async throws {
        let provider = FixedNavigationProvider(.init(kind: "fill", node: "n1", textBinding: "context"))
        let (authority, scope) = try await grant(provider: provider, phase: .setup, allowedFillBindings: ["approved"])
        let decision = await authority.review(method: "controller.decide", params: try decisionFields(scope, request()))
        XCTAssertEqual(decision.object?["kind"], .string("cannotProceed"))
        let empty = AutomationNavigationGoal(id: "goal", instruction: "Choose existing controls", endpoint: .init(.label, "Done"), allowedFillBindings: [])
        XCTAssertNoThrow(try empty.validate())
        XCTAssertThrowsError(try AutomationControllerDecision(kind: "fill", node: "n1", textBinding: "approved").action(request: request(), bindings: ["approved": "input"], phase: .setup, allowedFillBindings: []))
        for names in [["approved", "approved"], ["bad name"], Array(repeating: "approved", count: 31)] {
            let goal = AutomationNavigationGoal(id: "goal", instruction: "Create", endpoint: .init(.label, "Done"), allowedFillBindings: names)
            XCTAssertThrowsError(try goal.validate())
        }
        let excluded = AutomationNavigationGoal(id: "goal", instruction: "Create", endpoint: .init(.label, "Done"), minimumBindingUses: ["approved": 1], allowedFillBindings: ["context"])
        XCTAssertThrowsError(try excluded.validate())
        let unknown = AutomationNavigationGoal(id: "goal", instruction: "Create", endpoint: .init(.label, "Done"), allowedFillBindings: ["unknown"])
        XCTAssertThrowsError(try AutomationUIProgram(operations: [.init(id: "goal", kind: .navigateGoal, goal: unknown)], bindings: ["approved": "input"]).validate(phase: .setup))
    }
    func testKnownAndUnknownSelectionStateRoundTripsWithoutAuthority() throws {
        for selection in [true, false, nil] as [Bool?] {
            var observed = request(); observed.nodes[0].selected = selection
            let decoded = try JSONDecoder().decode(AutomationControllerRequest.self, from: JSONEncoder().encode(observed))
            XCTAssertEqual(decoded.nodes[0].selected, selection)
            XCTAssertEqual(decoded.nodes[0].id, observed.nodes[0].id)
        }
    }
    func testObservedTestIdentifierRoundTripsWithoutBecomingNodeAuthority() throws {
        var input = request(); input.nodes[0].testId = "task.title"
        try input.validate()
        let decoded = try JSONDecoder().decode(AutomationControllerRequest.self, from: JSONEncoder().encode(input))
        XCTAssertEqual(decoded.nodes[0].testId, "task.title")
        XCTAssertEqual(decoded.nodes[0].id, "n1")
        XCTAssertThrowsError(try AutomationControllerDecision(kind: "fill", node: "task.title", textBinding: "approved")
            .action(request: decoded, bindings: ["approved": "text"], phase: .setup))
        for invalid in ["", String(repeating: "x", count: 1025)] {
            input.nodes[0].testId = invalid
            XCTAssertThrowsError(try input.validate())
        }
    }
    func testProviderFailureDiagnosticCorrelatesValidatedRequestWithoutErrorMessage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let artifacts = try AutomationArtifactRegistry(root: root)
        let (authority, scope) = try await grant(provider: ThrowingNavigationProvider(), artifacts: artifacts)
        let result = await authority.review(method: "controller.decide", params: try decisionFields(scope, request()))
        XCTAssertEqual(result.object?["kind"], .string("cannotProceed"))
        let data = try Data(contentsOf: root.appendingPathComponent("controller-denied-\(scope.leaseGeneration)-1.json"))
        let record = try JSONDecoder().decode(AutomationJSON.self, from: data)
        XCTAssertEqual(record.object?["reason"], .string("provider"))
        XCTAssertEqual(record.object?["request"]?.object?["goalId"], .string("subject"))
        XCTAssertEqual(record.object?["scope"]?.object?["attemptId"], .string(scope.attemptId))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-error-content"))
    }
    func testPolicyDiagnosticsSeparateNodeAndValueMismatchWithoutConsumingGrant() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let artifacts = try AutomationArtifactRegistry(root: root)
        let (authority, scope) = try await grant(provider: FixedNavigationProvider(.init(kind: "fill", node: "n1", textBinding: "approved")), artifacts: artifacts)
        _ = await authority.review(method: "controller.decide", params: try decisionFields(scope, request()))
        var action = fields(scope)
        action["controllerNode"] = .string("private-wrong-node")
        action["action"] = .object(["kind": .string("fill"), "value": .string("private-wrong-value"), "sensitive": .bool(false)])
        let first = await authority.review(method: "policy.reviewAction", params: .object(action))
        XCTAssertEqual(first.object?["allowed"], .bool(false))
        XCTAssertEqual(first, .object(["allowed": .bool(false), "reason": .string("controllerNode")]))
        action["controllerNode"] = .string("n1")
        let second = await authority.review(method: "policy.reviewAction", params: .object(action))
        XCTAssertEqual(second.object?["allowed"], .bool(false))
        XCTAssertEqual(second, .object(["allowed": .bool(false), "reason": .string("actionMismatch")]))
        for (index, reason) in ["controllerNode", "actionMismatch"].enumerated() {
            let bytes = try Data(contentsOf: root.appendingPathComponent("policy-denied-\(scope.leaseGeneration)-\(index + 1).json"))
            let record = try JSONDecoder().decode(AutomationJSON.self, from: bytes)
            XCTAssertEqual(record.object?["reason"], .string(reason))
            XCTAssertEqual(record.object?["scope"], try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(scope)))
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("private-"))
        }
        action["action"] = .object(["kind": .string("fill"), "value": .string("test input"), "sensitive": .bool(false)])
        let accepted = await authority.review(method: "policy.reviewAction", params: .object(action))
        XCTAssertEqual(accepted.object?["allowed"], .bool(true))
    }
    func testPolicyDiagnosticCountIsBoundedAndIncomingScopeCannotBecomeEvidenceScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let artifacts = try AutomationArtifactRegistry(root: root)
        let (authority, scope) = try await grant(provider: FixedNavigationProvider(.init(kind: "finish")), artifacts: artifacts)
        var invalid = fields(scope); invalid["runId"] = .string("private-foreign-run")
        for _ in 0..<35 { _ = await authority.review(method: "policy.reviewAction", params: .object(invalid)) }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("policy-denied-") && $0.pathExtension == "json" }
        XCTAssertEqual(files.count, 32)
        for file in files { XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("private-foreign-run")) }
    }
    func testInvalidRequestDiagnosticNeverPersistsRejectedSecureText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let artifacts = try AutomationArtifactRegistry(root: root)
        let provider = FixedNavigationProvider(.init(kind: "finish"))
        let (authority, scope) = try await grant(provider: provider, artifacts: artifacts)
        var invalid = request(); invalid.nodes[0].secure = true; invalid.nodes[0].value = "private-rejected-content"
        _ = await authority.review(method: "controller.decide", params: try decisionFields(scope, invalid))
        let data = try Data(contentsOf: root.appendingPathComponent("controller-denied-\(scope.leaseGeneration)-1.json"))
        let record = try JSONDecoder().decode(AutomationJSON.self, from: data)
        XCTAssertEqual(record.object?["reason"], .string("requestValidation")); XCTAssertNil(record.object?["request"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-rejected-content"))
        let calls = await provider.calls; XCTAssertEqual(calls, 0)
    }
    func testRejectedDecisionShapeKeepsSafeFactsWithoutModelStrings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let artifacts = try AutomationArtifactRegistry(root: root)
        let provider = FixedNavigationProvider(.init(kind: "fill", node: "n1", textBinding: "private-binding", reason: "private-reason"))
        let (authority, scope) = try await grant(provider: provider, artifacts: artifacts)
        let result = await authority.review(method: "controller.decide", params: try decisionFields(scope, request()))
        XCTAssertEqual(result.object?["kind"], .string("cannotProceed"))
        let data = try Data(contentsOf: root.appendingPathComponent("controller-denied-\(scope.leaseGeneration)-1.json"))
        let record = try JSONDecoder().decode(AutomationJSON.self, from: data)
        XCTAssertEqual(record.object?["reason"], .string("decisionValidation"))
        let shape = record.object?["decisionShape"]?.object
        XCTAssertEqual(shape?["kind"], .string("fill")); XCTAssertEqual(shape?["nodeMatches"], .bool(true))
        XCTAssertEqual(shape?["reasonPresent"], .bool(true)); XCTAssertEqual(shape?["bindingPresent"], .bool(true))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-binding"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-reason"))
    }
    func testUnknownDecisionShapeDoesNotStoreItsRawKindOrNode() {
        let shape = AutomationControllerDecision(kind: "private-kind", node: "private-node").diagnosticShape(request: request())
        XCTAssertEqual(shape.object?["kind"], .string("unknown")); XCTAssertEqual(shape.object?["nodeMatches"], .bool(false))
        XCTAssertFalse(String(describing: shape).contains("private-kind")); XCTAssertFalse(String(describing: shape).contains("private-node"))
    }
    func testSupportedFillPathPreservesUnknownFactAndExplicitFalseOverrides() throws {
        var input = request(); input.nodes[0].editable = nil; input.nodes[0].fillSupported = true
        let bytes = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(AutomationControllerRequest.self, from: bytes)
        XCTAssertNil(decoded.nodes[0].editable); XCTAssertEqual(decoded.nodes[0].fillSupported, true)
        let decision = AutomationControllerDecision(kind: "fill", node: "n1", textBinding: "approved")
        XCTAssertNotNil(try decision.action(request: decoded, bindings: ["approved": "value"], phase: .setup))
        input.nodes[0].editable = false
        XCTAssertThrowsError(try decision.action(request: input, bindings: ["approved": "value"], phase: .setup))
        input.nodes[0].editable = nil; input.nodes[0].fillSupported = nil
        XCTAssertThrowsError(try decision.action(request: input, bindings: ["approved": "value"], phase: .setup))
    }
    func testRequiredInputCannotBeReplacedByVisibleEndpointOrForgedProgress() async throws {
        let provider = FixedNavigationProvider(.init(kind: "finish"))
        let (authority, scope) = try await grant(provider: provider, minimumBindingUses: ["approved": 1])
        var forged = request(); forged.approvedBindingUses = ["approved": 30]
        let result = await authority.review(method: "controller.decide", params: try decisionFields(scope, forged))
        XCTAssertEqual(result.object?["kind"], .string("cannotProceed"))
    }
    func testSaveCannotBeReplacedByVisibleEndpointOrForgedTap() async throws {
        let (authority, scope) = try await grant(provider: FixedNavigationProvider(.init(kind: "finish")), saveControl: .init(.label, "Save"))
        var forged = request(); forged.approvedSaveTap = true
        let result = await authority.review(method: "controller.decide", params: try decisionFields(scope, forged))
        XCTAssertEqual(result.object?["kind"], .string("cannotProceed"))
    }
    func testSaveControlRequiresDeclaredWriteEffects() async throws {
        do {
            _ = try await grant(provider: FixedNavigationProvider(.init(kind: "finish")), writes: false, saveControl: .init(.label, "Save"))
            XCTFail("Read-only navigation must not approve a save control")
        } catch { XCTAssertTrue(error is AutomationContractError) }
    }
    func testSaveControlCannotMatchAClippedLongerButtonLabel() throws {
        var goal = AutomationNavigationGoal(id: "subject", instruction: "Save the record", endpoint: .init(.label, "Form"))
        goal.saveControl = .init(.label, String(repeating: "s", count: 512))
        var node = request().nodes[0]; node.role = "button"; node.name = String(repeating: "s", count: 512)
        XCTAssertThrowsError(try goal.validate())
        XCTAssertFalse(goal.matchesSaveControl(node))
        node.name = String(repeating: "s", count: 512) + " another action"
        XCTAssertFalse(goal.matchesSaveControl(node))
    }
    func testOnlyConsumedSaveButtonTapUnlocksFinish() async throws {
        let provider = SaveProgressNavigationProvider()
        let (authority, scope) = try await grant(provider: provider, maximumControllerCalls: 2, saveControl: .init(.label, "Save"))
        var observed = request(); observed.nodes[0].role = "button"; observed.nodes[0].name = "Save"; observed.nodes[0].editable = nil
        let tap = await authority.review(method: "controller.decide", params: try decisionFields(scope, observed))
        XCTAssertEqual(tap.object?["kind"], .string("tap"))
        var action = fields(scope); action["controllerNode"] = .string("n1"); action["action"] = .object(["kind": .string("tap")])
        let allowed = await authority.review(method: "policy.reviewAction", params: .object(action))
        XCTAssertEqual(allowed.object?["allowed"], .bool(true))
        let finish = await authority.review(method: "controller.decide", params: try decisionFields(scope, observed))
        XCTAssertEqual(finish.object?["kind"], .string("finish"))
    }
    func testRequiredInputProgressOnlyCreditsConsumedApprovedBinding() async throws {
        let provider = InputProgressNavigationProvider()
        let (authority, scope) = try await grant(provider: provider, minimumBindingUses: ["approved": 1], maximumControllerCalls: 2)
        let fill = await authority.review(method: "controller.decide", params: try decisionFields(scope, request()))
        XCTAssertEqual(fill.object?["kind"], .string("fill"))
        var action = fields(scope); action["controllerNode"] = .string("n1")
        action["action"] = .object(["kind": .string("fill"), "value": .string("wrong input"), "sensitive": .bool(false)])
        let denied = await authority.review(method: "policy.reviewAction", params: .object(action))
        XCTAssertEqual(denied.object?["allowed"], .bool(false))
        action["action"] = .object(["kind": .string("fill"), "value": .string("test input"), "sensitive": .bool(false)])
        let allowed = await authority.review(method: "policy.reviewAction", params: .object(action))
        XCTAssertEqual(allowed.object?["allowed"], .bool(true))
        let finish = await authority.review(method: "controller.decide", params: try decisionFields(scope, request()))
        XCTAssertEqual(finish.object?["kind"], .string("finish"))
        let progress = await provider.progress; XCTAssertEqual(progress, [0, 1])
    }
    func testRequiredInputContractRejectsMissingBindingAndUnboundedCounts() throws {
        let goal = AutomationNavigationGoal(id: "create", instruction: "Create", endpoint: .init(.label, "Form"), minimumBindingUses: ["approved": 1])
        XCTAssertThrowsError(try AutomationUIProgram(operations: [.init(id: "create", kind: .navigateGoal, goal: goal)]).validate(phase: .setup))
        var tooMany = goal; tooMany.minimumBindingUses = ["approved": 31]
        XCTAssertThrowsError(try tooMany.validate())
    }
    func testDecisionBindsExactNodeAndInputThenCannotBeConsumedTwice() async throws {
        let provider = FixedNavigationProvider(.init(kind: "fill", node: "n1", textBinding: "approved"))
        let (authority, scope) = try await grant(provider: provider)
        let result = await authority.review(method: "controller.decide", params: try decisionFields(scope, request()))
        XCTAssertEqual(result.object?["kind"], .string("fill"))
        var action = fields(scope); action["action"] = .object(["kind": .string("fill"), "value": .string("test input"), "sensitive": .bool(false)])
        action["controllerNode"] = .string("other")
        let wrong = await authority.review(method: "policy.reviewAction", params: .object(action)); XCTAssertEqual(wrong.object?["allowed"], .bool(false))
        action["controllerNode"] = .string("n1")
        let right = await authority.review(method: "policy.reviewAction", params: .object(action)); XCTAssertEqual(right.object?["allowed"], .bool(true))
        let duplicate = await authority.review(method: "policy.reviewAction", params: .object(action)); XCTAssertEqual(duplicate.object?["allowed"], .bool(false))
        let next = await authority.review(method: "controller.decide", params: try decisionFields(scope, request())); XCTAssertEqual(next.object?["kind"], .string("cannotProceed"))
        let calls = await provider.calls; XCTAssertEqual(calls, 1)
    }
    func testBroadRunApprovalDoesNotAllowFillingNavigationOnlySegment() async throws {
        let provider = FixedNavigationProvider(.init(kind: "fill", node: "n1", textBinding: "approved"))
        let (authority, scope) = try await grant(provider: provider, writes: false)
        let result = await authority.review(method: "controller.decide", params: try decisionFields(scope, request()))
        XCTAssertEqual(result.object?["kind"], .string("cannotProceed")); let calls = await provider.calls; XCTAssertEqual(calls, 0)
    }
    func testLateDecisionAfterRevocationCannotGrantAnAction() async throws {
        let provider = SuspendedNavigationProvider()
        let (authority, scope) = try await grant(provider: provider)
        let input = try decisionFields(scope, request())
        let task = Task { await authority.review(method: "controller.decide", params: input) }
        while !(await provider.started) { await Task.yield() }
        try await authority.revoke(scope: scope)
        await provider.finish()
        let result = await task.value; XCTAssertEqual(result.object?["kind"], .string("cannotProceed"))
    }
    func testMalformedSecureObservationAndUnapprovedBindingsAreRejected() throws {
        var request = request(); request.nodes[0].secure = true; request.nodes[0].value = "secret"
        XCTAssertThrowsError(try request.validate())
        request.nodes[0].value = nil; request.nodes[0].text = "secret text"
        XCTAssertThrowsError(try request.validate())
        request.nodes[0].text = nil; request.nodes[0].secure = false
        XCTAssertThrowsError(try AutomationControllerDecision(kind: "fill", node: "n1", textBinding: "invented").action(request: request, bindings: ["approved": "value"], phase: .subject))
        XCTAssertThrowsError(try AutomationControllerDecision(kind: "finish", node: "n1").action(request: request, bindings: [:], phase: .subject))
        XCTAssertThrowsError(try AutomationControllerDecision(kind: "fill", node: "n1", textBinding: "approved").action(request: request, bindings: ["approved": "value"], phase: .observe))
    }
    func testViewportScrollingCannotCarryAnUnqualifiedNodeTarget() throws {
        let input = request()
        XCTAssertThrowsError(try AutomationControllerDecision(kind: "scroll", node: "n1", direction: "down").action(request: input, bindings: [:], phase: .setup))
        XCTAssertNotNil(try AutomationControllerDecision(kind: "scroll", direction: "down").action(request: input, bindings: [:], phase: .setup))
    }
    func testQueuedControllerActionExpiresWithGoalDeadline() async throws {
        let clock = NavigationTestClock()
        let (authority, scope) = try await grant(provider: FixedNavigationProvider(.init(kind: "tap", node: "n1")), now: { clock.read() })
        let decision = await authority.review(method: "controller.decide", params: try decisionFields(scope, request()))
        XCTAssertEqual(decision.object?["kind"], .string("tap"))
        clock.advance(seconds: 121)
        var action = fields(scope)
        action["action"] = .object(["kind": .string("tap")]); action["controllerNode"] = .string("n1")
        let result = await authority.review(method: "policy.reviewAction", params: .object(action))
        XCTAssertEqual(result.object?["allowed"], .bool(false))
    }
    func testGoalCannotHideWithinOtherOperationsOrObserverInputs() throws {
        let goal = AutomationNavigationGoal(id: "goal", instruction: "Navigate", endpoint: .init(.label, "Form"))
        XCTAssertThrowsError(try AutomationUIProgram(operations: [.init(id: "goal", kind: .navigateGoal, goal: goal), .init(id: "tap", kind: .tap, locator: .init(.label, "Other"))]).validate(phase: .setup))
        XCTAssertThrowsError(try AutomationUIProgram(operations: [.init(id: "goal", kind: .navigateGoal, goal: goal)], bindings: ["input": "text"]).validate(phase: .observe))
    }
    func testAggregateControllerCapStopsProviderAndExpiredCampaignStopsPolicy() async throws {
        var limits = AutomationCampaignLimits(); limits.controllerCalls = 0; limits.wallClockSeconds = 10
        let clock = NavigationTestClock(), budget = try AutomationCampaignBudget(limits: limits, now: { clock.read() })
        let provider = FixedNavigationProvider(.init(kind: "tap", node: "n1"))
        let (authority, scope) = try await grant(provider: provider, campaignBudget: budget)
        let decision = await authority.review(method: "controller.decide", params: try decisionFields(scope, request()))
        XCTAssertEqual(decision.object?["kind"], .string("cannotProceed"))
        let calls = await provider.calls; XCTAssertEqual(calls, 0)
        clock.advance(seconds: 11)
        do { try await budget.available(); XCTFail("Expired campaign accepted") } catch { }
        let usage = await budget.snapshot(); XCTAssertEqual(usage.controllerCalls, 0)
    }
    func testIndependentReadOperationsReserveObserverCapBeforeGrant() async throws {
        var limits = AutomationCampaignLimits(); limits.observerOperations = 1
        let budget = try AutomationCampaignBudget(limits: limits)
        let approval = RunApproval(runID: "read-run", app: app, target: target, environmentID: "unit", effects: [.observe, .navigate], maximumActions: 10, disposable: true)
        let leases = AutomationDeviceLeaseManager(), lease = try await leases.acquire(runID: approval.runID, target: target, control: .ui)
        let scope = AutomationScope(runID: approval.runID, attemptID: "reads", segmentID: "observer", leaseGeneration: lease.generation)
        let authority = AutomationRunAuthority(approval: approval, leases: leases, campaignBudget: budget)
        var segment = AutomationSegment(id: "observer", kind: .ui, phase: .observe, operation: "read", effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
        segment.uiProgram = .init(operations: [.init(id: "first", kind: .observeProperty, locator: .init(.label, "First"), property: "text"), .init(id: "second", kind: .observeProperty, locator: .init(.label, "Second"), property: "text")])
        do { try await authority.approve(scope: scope, lease: lease, segment: segment, actions: [.activate]); XCTFail("Read cap bypassed") } catch { }
        let usage = await budget.snapshot(); XCTAssertEqual(usage.reservedObserverOperations, 0)
    }

}
private struct SaveProgressNavigationProvider: AutomationControllerDecisionProvider {
    func decide(goal: AutomationNavigationGoal, request: AutomationControllerRequest, bindings: [String: String]) async throws -> AutomationControllerDecision {
        request.approvedSaveTap == true ? .init(kind: "finish") : .init(kind: "tap", node: "n1")
    }
}
private actor FixedNavigationProvider: AutomationControllerDecisionProvider {
    let decision: AutomationControllerDecision
    var calls = 0
    init(_ decision: AutomationControllerDecision) { self.decision = decision }
    func decide(goal: AutomationNavigationGoal, request: AutomationControllerRequest, bindings: [String: String]) async throws -> AutomationControllerDecision { calls += 1; return decision }
}
private actor SuspendedNavigationProvider: AutomationControllerDecisionProvider {
    var started = false
    var pending: CheckedContinuation<AutomationControllerDecision, Never>?
    func decide(goal: AutomationNavigationGoal, request: AutomationControllerRequest, bindings: [String: String]) async throws -> AutomationControllerDecision {
        started = true; return await withCheckedContinuation { pending = $0 }
    }
    func finish() { pending?.resume(returning: .init(kind: "tap", node: "n1")); pending = nil }
}

private final class NavigationTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    func read() -> ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return instant }
    func advance(seconds: Int) { lock.lock(); defer { lock.unlock() }; instant = instant.advanced(by: .seconds(seconds)) }
}

private struct ThrowingNavigationProvider: AutomationControllerDecisionProvider {
    struct Failure: Error, CustomStringConvertible { let description = "private-error-content" }
    func decide(goal: AutomationNavigationGoal, request: AutomationControllerRequest, bindings: [String: String]) async throws -> AutomationControllerDecision {
        throw Failure()
    }
}

private actor InputProgressNavigationProvider: AutomationControllerDecisionProvider {
    var progress: [Int] = []
    func decide(goal: AutomationNavigationGoal, request: AutomationControllerRequest, bindings: [String: String]) async throws -> AutomationControllerDecision {
        let count = request.approvedBindingUses?["approved"] ?? 0; progress.append(count)
        return count == 0 ? .init(kind: "fill", node: "n1", textBinding: "approved") : .init(kind: "finish")
    }
}
