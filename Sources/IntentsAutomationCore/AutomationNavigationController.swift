import Foundation

public struct AutomationNavigationGoal: Codable, Equatable, Sendable {
    public var id: String
    public var instruction: String
    public var endpoint: AutomationUIProgram.Locator
    public var maximumCalls: Int
    public var maximumActions: Int
    public var minimumBindingUses: [String: Int]?
    public var allowedFillBindings: [String]?
    /// Existing option values to select; their observed selected state is not save evidence.
    public var selectionBindings: [String]?
    public var saveControl: AutomationUIProgram.Locator? = nil
    public init(id: String, instruction: String, endpoint: AutomationUIProgram.Locator, maximumCalls: Int = 12, maximumActions: Int = 30, minimumBindingUses: [String: Int]? = nil, allowedFillBindings: [String]? = nil, selectionBindings: [String]? = nil) {
        self.id = id; self.instruction = instruction; self.endpoint = endpoint; self.maximumCalls = maximumCalls; self.maximumActions = maximumActions; self.minimumBindingUses = minimumBindingUses; self.allowedFillBindings = allowedFillBindings
        self.selectionBindings = selectionBindings
    }
    public func validate() throws {
        guard id.range(of: #"^[A-Za-z0-9_.:-]{1,256}$"#, options: .regularExpression) != nil,
              !instruction.isEmpty, instruction.utf16.count <= 4096, !endpoint.value.isEmpty, endpoint.value.utf16.count <= 1024, endpoint.role == nil, endpoint.kind != .role,
              (1...12).contains(maximumCalls), (1...30).contains(maximumActions) else { throw AutomationContractError.invalidPlan("Malformed navigation goal") }
        if let allowedFillBindings {
            guard (0...30).contains(allowedFillBindings.count), Set(allowedFillBindings).count == allowedFillBindings.count,
                  allowedFillBindings.allSatisfy(AutomationHostProgram.identifier),
                  Set((minimumBindingUses ?? [:]).keys).isSubset(of: Set(allowedFillBindings)) else {
                throw AutomationContractError.invalidPlan("Malformed permitted fill bindings")
            }
        }
        if let minimumBindingUses {
            guard !minimumBindingUses.isEmpty, minimumBindingUses.count <= 30,
                  minimumBindingUses.allSatisfy({ AutomationHostProgram.identifier($0.key) && (1...30).contains($0.value) }),
                  minimumBindingUses.values.reduce(0,+) <= maximumActions else { throw AutomationContractError.invalidPlan("Malformed required input activity") }
        }
        if let selectionBindings {
            guard allowedFillBindings != nil, (1...30).contains(selectionBindings.count), Set(selectionBindings).count == selectionBindings.count,
                  selectionBindings.allSatisfy(AutomationHostProgram.identifier),
                  Set(selectionBindings).isDisjoint(with: Set(allowedFillBindings ?? [])) else {
                throw AutomationContractError.invalidPlan("Malformed option selection bindings")
            }
        }
        if let saveControl {
            guard saveControl.kind != .role, saveControl.role == nil, !saveControl.value.isEmpty,
                  saveControl.value.utf16.count <= 1024,
                  saveControl.kind != .label || saveControl.value.utf16.count < 512 else { throw AutomationContractError.invalidPlan("Malformed save control") }
        }
    }
    func matchesSaveControl(_ node: AutomationControllerRequest.Node) -> Bool {
        guard let saveControl, node.role == "button", node.visible, !node.disabled, !node.secure else { return false }
        return saveControl.kind == .testId ? node.testId == saveControl.value
            : (node.name?.utf16.count ?? 512) < 512 && node.name == saveControl.value
    }
}

public struct AutomationControllerRequest: Codable, Equatable, Sendable {
    public struct Node: Codable, Equatable, Sendable {
        public var id: String
        public var role: String?
        public var name: String?
        public var testId: String? = nil
        public var selected: Bool? = nil
        public var text: String?
        public var value: String?
        public var editable: Bool?
        public var fillSupported: Bool? = nil
        public var visible: Bool
        public var disabled: Bool
        public var secure: Bool
    }
    public var goalId: String
    public var revision: String
    public var nodes: [Node]
    public var truncated: Bool
    public var omittedNodes: Int
    public var verbs: [String]
    public var recentActions: [String]
    public var remainingActions: Int
    public var remainingMs: Int
    public var approvedBindingUses: [String: Int]? = nil
    public var approvedSaveTap: Bool? = nil
    public func validate() throws {
        if let approvedBindingUses {
            guard approvedBindingUses.count <= 30, approvedBindingUses.allSatisfy({ AutomationHostProgram.identifier($0.key) && (0...30).contains($0.value) }),
                  approvedBindingUses.values.reduce(0,+) <= 30 else { throw AutomationContractError.invalidPlan("Malformed input activity") }
        }
        guard !revision.isEmpty, revision.utf16.count <= 256, nodes.count <= 200, Set(nodes.map(\.id)).count == nodes.count,
              (0...5000).contains(omittedNodes), (0...30).contains(remainingActions), (1...120_000).contains(remainingMs),
              recentActions.count <= 4, recentActions.allSatisfy({ $0.utf16.count <= 512 }), Set(verbs).count == verbs.count,
              Set(verbs).isSubset(of: ["tap", "fill", "scroll", "pressKey", "back"]),
              nodes.allSatisfy({ node in
                  node.id.range(of: #"^[A-Za-z0-9_.:-]{1,256}$"#, options: .regularExpression) != nil &&
                  (node.role?.utf16.count ?? 0) <= 128 && (node.name?.utf16.count ?? 0) <= 512 &&
                  (node.testId == nil || (!node.testId!.isEmpty && node.testId!.utf16.count <= 1024)) &&
                  (node.text?.utf16.count ?? 0) <= 512 && (node.value?.utf16.count ?? 0) <= 1024 && (!node.secure || (node.value == nil && node.text == nil))
              }) else { throw AutomationContractError.invalidPlan("Malformed redacted controller observation") }
    }
}

public struct AutomationControllerDecision: Codable, Equatable, Sendable {
    public var kind: String
    public var node: String?
    public var textBinding: String?
    public var direction: String?
    public var key: String?
    public var reason: String?
    public init(kind: String, node: String? = nil, textBinding: String? = nil, direction: String? = nil, key: String? = nil, reason: String? = nil) {
        self.kind = kind; self.node = node; self.textBinding = textBinding; self.direction = direction; self.key = key; self.reason = reason
    }
    /// Only fixed vocabulary and presence/match booleans enter rejected-decision
    /// diagnostics. Model-provided strings never become diagnostic contents.
    func diagnosticShape(request: AutomationControllerRequest) -> AutomationJSON {
        let selected = node.flatMap { id in request.nodes.first { $0.id == id } }
        var fields: [String: AutomationJSON] = [
            "kind": .string(["tap", "fill", "scroll", "finish", "cannotProceed"].contains(kind) ? kind : "unknown"),
            "nodePresent": .bool(node != nil), "nodeMatches": .bool(selected != nil),
            "bindingPresent": .bool(textBinding != nil), "directionPresent": .bool(direction != nil),
            "keyPresent": .bool(key != nil), "reasonPresent": .bool(reason != nil)
        ]
        if let selected {
            fields["nodeVisible"] = .bool(selected.visible); fields["nodeEditable"] = selected.editable.map(AutomationJSON.bool) ?? .null
            fields["nodeFillSupported"] = .bool(selected.fillSupported == true)
            fields["nodeDisabled"] = .bool(selected.disabled); fields["nodeSecure"] = .bool(selected.secure)
        }
        return .object(fields)
    }
    /// A decision can only nominate an action that the native engine and frozen input bindings support.
    public func action(request: AutomationControllerRequest, bindings: [String: String], phase: AutomationSegment.Phase, allowedFillBindings: [String]? = nil) throws -> AutomationRunAuthority.Action? {
        try request.validate()
        if kind == "finish" {
            guard node == nil, textBinding == nil, direction == nil, key == nil, reason == nil else { throw AutomationContractError.invalidIdentity }
            return nil
        }
        if kind == "cannotProceed" {
            guard ["modelUnavailable", "unsupportedObservation", "navigationStalled", "budgetExhausted", "noSafeAction"].contains(reason),
                  node == nil, textBinding == nil, direction == nil, key == nil else { throw AutomationContractError.invalidIdentity }
            return nil
        }
        guard request.verbs.contains(kind), key == nil, reason == nil, request.remainingActions > 0 else { throw AutomationContractError.invalidIdentity }
        let selected = node.flatMap { id in request.nodes.first { $0.id == id } }
        switch kind {
        case "tap":
            guard let selected, selected.visible, !selected.disabled, textBinding == nil, direction == nil else { throw AutomationContractError.invalidIdentity }
            return .tap
        case "fill":
            guard phase != .observe, let selected, selected.visible, selected.editable != false, (selected.editable == true || selected.fillSupported == true), !selected.disabled, !selected.secure,
                  let textBinding, let value = bindings[textBinding], direction == nil,
                  allowedFillBindings == nil || allowedFillBindings!.contains(textBinding) else { throw AutomationContractError.invalidIdentity }
            return .fill(value)
        case "scroll":
            guard textBinding == nil, ["up", "down", "left", "right"].contains(direction), node == nil else { throw AutomationContractError.missingEvidence("Only viewport scrolling is qualified") }
            return .swipe(direction!)
        default: throw AutomationContractError.missingEvidence("Native back and key control are not qualified")
        }
    }
}

public protocol AutomationControllerDecisionProvider: Sendable {
    func decide(goal: AutomationNavigationGoal, request: AutomationControllerRequest, bindings: [String: String]) async throws -> AutomationControllerDecision
}
