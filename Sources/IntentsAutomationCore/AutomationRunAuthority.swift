import Foundation

/// Swift grants only the actions of the frozen segment, in order and under its current lease.
public actor AutomationRunAuthority {
    public enum Action: Equatable, Sendable {
        case activate, tap, fill(String), fillSecret(referenceID: String, sinkID: String), swipe(String)
        public static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.activate, .activate), (.tap, .tap): return true
            // A replacement grant binds the exact approved code units. Swift's
            // ordinary String equality also accepts canonically equivalent text.
            case (.fill(let left), .fill(let right)): return left.utf16.elementsEqual(right.utf16)
            case (.swipe(let left), .swipe(let right)): return left == right
            case (.fillSecret(let leftReference, let leftSink), .fillSecret(let rightReference, let rightSink)):
                return leftReference == rightReference && leftSink == rightSink
            default: return false
            }
        }
    }
    private struct Grant: Sendable {
        var scope: AutomationScope
        var actions: [Action]
        var consumed = 0
        var goal: AutomationNavigationGoal?
        var bindings: [String: String]
        var phase: AutomationSegment.Phase
        var mayFill: Bool
        var calls = 0
        var maximumCalls: Int
        var maximumActions: Int
        var deadline: ContinuousClock.Instant?
        var pendingNode: String?
        var pendingBinding: String?
        var setupTrace = AutomationSetupTrace()
        var goalFinished = false
        var approvedBindingUses: [String: Int] = [:]
        var pendingSaveTap = false
        var approvedSaveTap = false
    }
    private let approval: RunApproval
    private let leases: AutomationDeviceLeaseManager
    private var grant: Grant?
    private var actionCount = 0
    private var reviewing = false
    private var controllerCalls = 0
    private var denialDiagnostics = 0
    private var policyDiagnostics = 0
    private let controller: any AutomationControllerDecisionProvider
    private let artifacts: AutomationArtifactRegistry?
    private let campaignBudget: AutomationCampaignBudget?
    private let now: @Sendable () -> ContinuousClock.Instant
    public init(approval: RunApproval, leases: AutomationDeviceLeaseManager, controller: any AutomationControllerDecisionProvider = AutomationFoundationController(), artifacts: AutomationArtifactRegistry? = nil, campaignBudget: AutomationCampaignBudget? = nil, now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.approval = approval; self.leases = leases; self.controller = controller; self.artifacts = artifacts
        self.now = now; self.campaignBudget = campaignBudget
    }
    func matchesSecretContext(_ expected: RunApproval, evidenceRoot: URL) async -> Bool {
        guard approval == expected, let artifacts else { return false }
        return await artifacts.secretEvidenceRoot() == evidenceRoot
    }
    public func approve(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease,
                        segment: AutomationSegment, actions: [Action], maximumControllerCalls: Int = 0, maximumUIActions: Int? = nil) async throws {
        try scope.validate()
        try segment.uiProgram?.validate(phase: segment.phase)
        guard grant == nil, scope.runId == approval.runID, scope.segmentId == segment.id,
              scope.leaseGeneration == lease.generation, lease.runID == approval.runID, lease.target == approval.target,
              lease.control == .ui, await leases.isCurrent(lease),
              segment.effects.isSubset(of: approval.effects), actions.count <= approval.maximumActions - actionCount,
              !actions.isEmpty, actions.first == .activate,
              segment.lifecycle == .persistedStateAcrossSegments, segment.effects.contains(.navigate),
              !actions.contains(where: { switch $0 { case .fill, .fillSecret: true; default: false } }) ||
                segment.effects.contains(.fixtureWrite) || segment.effects.contains(.externalWrite),
              segment.phase != .observe || !actions.contains(where: { switch $0 { case .fill, .fillSecret: true; default: false } }) else {
            throw AutomationContractError.invalidPlan("Action grant does not match approved plan and lease")
        }
        guard grant == nil else { throw AutomationContractError.targetBusy }
        let goal = segment.uiProgram?.operations.first?.goal
        guard goal?.saveControl == nil || (segment.phase != .observe && !segment.effects.isDisjoint(with: [.fixtureWrite, .externalWrite])) else {
            throw AutomationContractError.invalidPlan("Save control requires approved write effects")
        }
        let remainingActions = min(approval.maximumActions, maximumUIActions ?? approval.maximumActions) - actionCount
        guard actions.count <= remainingActions, goal == nil || (maximumControllerCalls > controllerCalls && remainingActions > 1) else { throw AutomationContractError.invalidPlan("Controller or action budget is unavailable") }
        let reads = segment.uiProgram?.operations.reduce(0) { count, operation in
            switch operation.kind {
            case .observeProperty, .readProperty, .locate, .assertEndpoint: return count + 1
            case .navigateGoal: return count + (operation.goal?.maximumCalls ?? 12) * 2
            default: return count
            }
        } ?? 0
        if reads > 0 { try await campaignBudget?.reserveOperations(id: scope.attemptId + "." + scope.segmentId + ".readback", phase: segment.phase, count: reads) }
        guard await leases.isCurrent(lease), grant == nil else { throw AutomationContractError.unknownLease }
        try campaignBudget?.validateDeadline()
        grant = Grant(scope: scope, actions: actions, goal: goal, bindings: segment.uiProgram?.bindings ?? [:], phase: segment.phase,
                      mayFill: segment.phase != .observe && (segment.effects.contains(.fixtureWrite) || segment.effects.contains(.externalWrite)),
                      maximumCalls: maximumControllerCalls, maximumActions: remainingActions)
    }
    public func review(method: String, params: AutomationJSON) async -> AutomationJSON {
        guard !reviewing else { return .object(["allowed": .bool(false)]) }
        reviewing = true; defer { reviewing = false }
        if method == "controller.decide" {
            if let scope = grant?.scope, let artifacts, !(await artifacts.canExposeEvidence(scope: scope)) {
                return await policyDenied(scope: scope, reason: .actionShape)
            }
            return await decide(params)
        }
        guard method == "policy.reviewAction", let fields = params.object, var active = grant,
              fields["protocolVersion"] == .number(1), fields["runId"] == .string(active.scope.runId),
              fields["attemptId"] == .string(active.scope.attemptId), fields["segmentId"] == .string(active.scope.segmentId),
              fields["leaseGeneration"] == .number(Double(active.scope.leaseGeneration)),
              active.consumed < active.actions.count, actionCount < approval.maximumActions else { return await policyDenied(scope: grant?.scope, reason: .scopeEnvelope) }
        let candidate: Action
        if fields["effect"] == .string("activate"), let target = fields["target"]?.object,
           Set(fields.keys) == ["protocolVersion", "runId", "attemptId", "segmentId", "leaseGeneration", "effect", "target"],
           target == ["id": .string(approval.target.id), "platform": .string(approval.target.kind == .nativeMac ? "macos" : "ios"),
                      "kind": .string(approval.target.kind.rawValue), "bundleId": .string(approval.app.bundleID),
                      "bundlePath": approval.target.kind == .nativeMac ? approval.app.canonicalBundlePath.map(AutomationJSON.string) ?? .null : .null,
                      "loginSession": approval.target.loginSession.map(AutomationJSON.string) ?? .null] { candidate = .activate }
        else if let action = fields["action"]?.object {
            let expectedKeys: Set<String> = ["protocolVersion", "runId", "attemptId", "segmentId", "leaseGeneration", "action"]
            guard Set(fields.keys) == expectedKeys || Set(fields.keys) == expectedKeys.union(["controllerNode"]) else { return await policyDenied(scope: active.scope, reason: .actionShape) }
            if active.goal != nil { guard fields["controllerNode"] == active.pendingNode.map(AutomationJSON.string) else { return await policyDenied(scope: active.scope, reason: .controllerNode) } }
            switch action["kind"] {
            case .string("tap"): guard Set(action.keys) == ["kind"] else { return await policyDenied(scope: active.scope, reason: .actionShape) }; candidate = .tap
            case .string("fill"):
                guard let text = action["value"]?.string, text.utf16.count <= 32768, action["sensitive"] == .bool(false),
                      Set(action.keys) == ["kind", "value", "sensitive"] else { return await policyDenied(scope: active.scope, reason: .actionShape) }; candidate = .fill(text)
            case .string("fillSecret"):
                guard active.goal == nil, let reference = action["referenceID"]?.string, UUID(uuidString: reference) != nil,
                      let sink = action["sinkID"]?.string, !sink.isEmpty, sink.utf8.count <= 256,
                      Set(action.keys) == ["kind", "referenceID", "sinkID"] else { return await policyDenied(scope: active.scope, reason: .actionShape) }
                candidate = .fillSecret(referenceID: reference, sinkID: sink)
            case .string("swipe"):
                guard let direction = action["direction"]?.string, ["up", "down", "left", "right"].contains(direction),
                      Set(action.keys) == ["kind", "direction"] else { return await policyDenied(scope: active.scope, reason: .actionShape) }; candidate = .swipe(direction)
            default: return await policyDenied(scope: active.scope, reason: .actionShape)
            }
        } else { return await policyDenied(scope: active.scope, reason: .actionShape) }
        let expectedLease = AutomationDeviceLeaseManager.Lease(runID: approval.runID, target: approval.target,
                                                               generation: active.scope.leaseGeneration, control: .ui)
        guard await leases.isCurrent(expectedLease), grant?.scope == active.scope else { return await policyDenied(scope: active.scope, reason: .scopeLease) }
        guard active.actions[active.consumed] == candidate else { return await policyDenied(scope: active.scope, reason: .actionMismatch) }
        if active.goal != nil && candidate != .activate {
            guard let deadline = active.deadline, now() < deadline else { return await policyDenied(scope: active.scope, reason: .deadline) }
        }
        if let campaignBudget {
            do { try await campaignBudget.reserveOperations(id: active.scope.attemptId + "." + active.scope.segmentId + "." + String(active.consumed), phase: active.phase, count: 1, uiActions: 1) }
            catch { return await policyDenied(scope: active.scope, reason: .budget) }
            guard await leases.isCurrent(expectedLease), grant?.scope == active.scope else { return await policyDenied(scope: active.scope, reason: .scopeLease) }
        }
        do { try campaignBudget?.validateDeadline() } catch { return await policyDenied(scope: active.scope, reason: .budget) }
        if case .fill = candidate, let name = active.pendingBinding { active.approvedBindingUses[name, default: 0] += 1 }
        if case .tap = candidate, active.pendingSaveTap { active.approvedSaveTap = true }
        if active.goal != nil && candidate != .activate { active.setupTrace.consume() }
        active.pendingBinding = nil
        active.pendingSaveTap = false
        active.consumed += 1; active.pendingNode = nil; grant = active; actionCount += 1
        return .object(["allowed": .bool(true)])
    }
    private enum PolicyDenial: String { case scopeEnvelope, actionShape, controllerNode, scopeLease, actionMismatch, deadline, budget }
    private func policyDenied(scope: AutomationScope?, reason: PolicyDenial) async -> AutomationJSON {
        if let scope, let artifacts, policyDiagnostics < 32 {
            policyDiagnostics += 1
            if let scoped = try? JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(scope)),
               let bytes = try? JSONEncoder().encode(AutomationJSON.object([
                   "event": .string("policyDenied"), "scope": scoped, "reason": .string(reason.rawValue)])) {
                _ = try? await artifacts.store(data: bytes, name: "policy-denied-\(scope.leaseGeneration)-\(policyDiagnostics).json", scope: scope)
            }
        }
        return .object(["allowed": .bool(false), "reason": .string(reason.rawValue)])
    }
    func capturedSetup(scope: AutomationScope) -> AutomationControllerSetupCapture? {
        guard let active = grant, active.scope == scope, active.phase == .setup,
              active.consumed == active.actions.count, let goal = active.goal else { return nil }
        return active.setupTrace.capture(scope: scope, goal: goal)
    }
    public func revoke(scope: AutomationScope) throws {
        guard grant?.scope == scope else { throw AutomationContractError.unknownLease }; grant = nil
    }
    private func decide(_ params: AutomationJSON) async -> AutomationJSON {
        let denied: AutomationJSON = .object(["kind": .string("cannotProceed"), "reason": .string("noSafeAction")])
        guard let fields = params.object, var active = grant, let goal = active.goal,
              fields["protocolVersion"] == .number(1), fields["runId"] == .string(active.scope.runId),
              fields["attemptId"] == .string(active.scope.attemptId), fields["segmentId"] == .string(active.scope.segmentId),
              fields["leaseGeneration"] == .number(Double(active.scope.leaseGeneration)),
              Set(fields.keys) == ["protocolVersion", "runId", "attemptId", "segmentId", "leaseGeneration", "request"] else {
            return await controllerDenied(scope: grant?.scope, reason: "scopeEnvelope")
        }
        guard !active.goalFinished, active.consumed == active.actions.count else { return await controllerDenied(scope: active.scope, reason: "unconsumedAction") }
        let lease = AutomationDeviceLeaseManager.Lease(runID: approval.runID, target: approval.target, generation: active.scope.leaseGeneration, control: .ui)
        var stage = "leaseValidation"
        var validatedRequest: AutomationControllerRequest?
        var returnedDecision: AutomationControllerDecision?
        do {
            guard await leases.isCurrent(lease), grant?.scope == active.scope else { return await controllerDenied(scope: active.scope, reason: stage) }
            stage = "requestValidation"
            var request = try JSONDecoder().decode(AutomationControllerRequest.self, from: JSONEncoder().encode(fields["request"]!))
            try request.validate(); validatedRequest = request
            stage = "requestPolicy"
            guard request.goalId == goal.id, active.calls < goal.maximumCalls, controllerCalls < active.maximumCalls,
                  active.actions.count < active.maximumActions,
                  !request.verbs.contains("fill") || active.mayFill,
                  Set(request.verbs).isSubset(of: ["tap", "fill", "scroll"]) else {
                return await controllerDenied(scope: active.scope, reason: stage, request: validatedRequest)
            }
            if active.deadline == nil { active.deadline = now().advanced(by: .seconds(120)) }
            guard let deadline = active.deadline, now() < deadline else { return .object(["kind": .string("cannotProceed"), "reason": .string("budgetExhausted")]) }
            if let campaignBudget {
                try await campaignBudget.reserveControllerCall(id: active.scope.attemptId + "." + active.scope.segmentId + "." + String(active.calls))
                guard await leases.isCurrent(lease), grant?.scope == active.scope else { return denied }
            }
            try campaignBudget?.validateDeadline()
            active.calls += 1; controllerCalls += 1; grant = active
            request.approvedBindingUses = active.approvedBindingUses
            request.approvedSaveTap = active.approvedSaveTap
            request.remainingActions = min(request.remainingActions, active.maximumActions - active.actions.count, goal.maximumActions - active.actions.count + 1)
            let callDeadline = min(deadline, campaignBudget?.deadline ?? deadline, ContinuousClock.now.advanced(by: .milliseconds(min(30_000, request.remainingMs))))
            let provider = controller, bindings = active.bindings, boundedRequest = request
            stage = "provider"
            let exposure = try await artifacts?.reserveModelEvidence(scope: active.scope)
            let decision = try await AutomationBoundedTask<AutomationControllerDecision>().run(until: callDeadline) {
                defer { exposure?.release() }
                return try await provider.decide(goal: goal, request: boundedRequest, bindings: bindings)
            }
            returnedDecision = decision
            stage = "decisionValidation"
            let action = try decision.action(request: request, bindings: active.bindings, phase: active.phase, allowedFillBindings: goal.allowedFillBindings)
            if decision.kind == "finish", !(goal.minimumBindingUses ?? [:]).allSatisfy({ active.approvedBindingUses[$0.key, default: 0] >= $0.value }) {
                throw AutomationContractError.missingEvidence("Required approved input activity is incomplete")
            }
            if decision.kind == "finish", goal.saveControl != nil, !active.approvedSaveTap {
                throw AutomationContractError.missingEvidence("Required save control activity is incomplete")
            }
            let saveTap = decision.kind == "tap" && request.nodes.contains { $0.id == decision.node && goal.matchesSaveControl($0) }
            if saveTap && active.approvedSaveTap { throw AutomationContractError.conflictingOperation }
            guard await leases.isCurrent(lease), grant?.scope == active.scope, grant?.calls == active.calls, now() < deadline else { return denied }
            let response = try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(decision))
            if let artifacts {
                let record: AutomationJSON = .object(["scope": try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(active.scope)), "request": fields["request"]!, "decision": response])
                _ = try await artifacts.store(data: JSONEncoder().encode(record), name: "controller-\(active.scope.leaseGeneration)-\(active.calls).json", scope: active.scope)
            }
            guard await leases.isCurrent(lease), grant?.scope == active.scope, now() < deadline else { return denied }
            try campaignBudget?.validateDeadline()
            if active.phase == .setup { active.setupTrace.prepare(decision, request: request) }
            if decision.kind == "finish" { active.goalFinished = true }
            if let action { active.actions.append(action); active.pendingNode = decision.node ?? "root"; active.pendingBinding = decision.kind == "fill" ? decision.textBinding : nil }
            active.pendingSaveTap = saveTap
            grant = active
            return response
        } catch {
            return await controllerDenied(scope: active.scope, reason: stage, request: validatedRequest,
                errorType: String(reflecting: type(of: error)), decision: returnedDecision)
        }
    }
    /// Diagnostics record this authority's known scope, never a rejected raw
    /// payload, error description or execution grant. Bound denial log growth.
    private func controllerDenied(scope: AutomationScope?, reason: String, request: AutomationControllerRequest? = nil,
                                  errorType: String? = nil, decision: AutomationControllerDecision? = nil) async -> AutomationJSON {
        if let scope, let artifacts, denialDiagnostics < 32 {
            denialDiagnostics += 1
            var record: [String: AutomationJSON] = ["event": .string("controllerDenied"), "reason": .string(reason)]
            if let value = try? JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(scope)) { record["scope"] = value }
            // Only a successfully validated redacted request may enter evidence.
            if let request, let value = try? JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(request)) { record["request"] = value }
            if let decision, let request { record["decisionShape"] = decision.diagnosticShape(request: request) }
            if let errorType { record["errorType"] = .string(String(errorType.prefix(256))) }
            if let data = try? JSONEncoder().encode(AutomationJSON.object(record)) {
                _ = try? await artifacts.store(data: data, name: "controller-denied-\(scope.leaseGeneration)-\(denialDiagnostics).json", scope: scope)
            }
        }
        return .object(["kind": .string("cannotProceed"), "reason": .string("noSafeAction")])
    }
}
