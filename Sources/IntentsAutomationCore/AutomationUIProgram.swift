import Foundation

public struct AutomationUIProgram: Codable, Equatable, Sendable {
    public struct Locator: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case testId, label, role }
        public enum Role: String, Codable, Sendable { case button }
        public var kind: Kind
        public var value: String
        public var role: Role?
        public init(_ kind: Kind, _ value: String, role: Role? = nil) { self.kind = kind; self.value = value; self.role = role }
    }
    public struct Operation: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case tap, fillBinding, readProperty, observeProperty, assertEndpoint, locate, scroll, navigateGoal }
        public var kind: Kind
        public var id: String
        public var locator: Locator?
        public var binding: String?
        public var property: String?
        public var direction: String?
        public var goal: AutomationNavigationGoal?
        public init(id: String, kind: Kind, locator: Locator? = nil, binding: String? = nil, property: String? = nil, direction: String? = nil, goal: AutomationNavigationGoal? = nil) {
            self.id = id; self.kind = kind; self.locator = locator; self.binding = binding; self.property = property; self.direction = direction; self.goal = goal
        }
    }
    public var operations: [Operation]
    public var bindings: [String: String]
    public var timeoutMilliseconds: Int
    public init(operations: [Operation], bindings: [String: String] = [:], timeoutMilliseconds: Int = 120_000) {
        self.operations = operations; self.bindings = bindings; self.timeoutMilliseconds = timeoutMilliseconds
    }
    public func validate(phase: AutomationSegment.Phase) throws {
        guard (1...30).contains(operations.count), bindings.count <= 30, (100...120_000).contains(timeoutMilliseconds),
              Set(operations.map(\.id)).count == operations.count,
              bindings.allSatisfy({ Self.identifier($0.key) && $0.value.utf16.count <= 32768 }) else {
            throw AutomationContractError.invalidPlan("Malformed UI program")
        }
        for operation in operations {
            guard Self.identifier(operation.id) else { throw AutomationContractError.invalidIdentity }
            if operation.kind == .navigateGoal {
                guard operations.count == 1, let goal = operation.goal, goal.id == operation.id,
                      operation.locator == nil, operation.binding == nil, operation.property == nil, operation.direction == nil,
                      phase != .observe || (bindings.isEmpty && goal.saveControl == nil) else { throw AutomationContractError.invalidPlan("Ambiguous navigation goal or observer inputs") }
                try goal.validate()
                guard Set((goal.minimumBindingUses ?? [:]).keys).isSubset(of: Set(bindings.keys)) else { throw AutomationContractError.invalidPlan("Required input activity has no approved binding") }
                guard Set(goal.allowedFillBindings ?? []).isSubset(of: Set(bindings.keys)) else { throw AutomationContractError.invalidPlan("Permitted fill has no approved binding") }
                guard Set(goal.selectionBindings ?? []).isSubset(of: Set(bindings.keys)) else { throw AutomationContractError.invalidPlan("Option selection has no approved binding") }
                continue
            }
            guard operation.goal == nil else { throw AutomationContractError.invalidPlan("Goal attached to a deterministic operation") }
            if operation.kind == .scroll {
                guard operation.locator == nil, operation.binding == nil, operation.property == nil,
                      ["up", "down", "left", "right"].contains(operation.direction) else { throw AutomationContractError.invalidPlan("Invalid scroll") }
                continue
            }
            guard let locator = operation.locator, !locator.value.isEmpty, locator.value.utf16.count <= 1024, operation.direction == nil else {
                throw AutomationContractError.invalidPlan("Missing exact UI locator")
            }
            guard locator.kind != .role || (operation.kind == .fillBinding && ["textbox", "searchbox"].contains(locator.value)) else {
                throw AutomationContractError.missingEvidence("Role locators support only ordinary textbox or searchbox fill")
            }
            guard locator.role == nil || (operation.kind == .tap && locator.kind == .label) else {
                throw AutomationContractError.invalidPlan("A button role can only qualify an exact tap label")
            }
            switch operation.kind {
            case .fillBinding:
                guard phase != .observe, let binding = operation.binding, Self.identifier(binding),
                      bindings[binding] != nil, operation.property == nil else { throw AutomationContractError.invalidPlan("Missing fill binding or observer mutation") }
            case .observeProperty:
                guard ["text", "value", "checked", "selected"].contains(operation.property), operation.binding == nil else { throw AutomationContractError.invalidPlan("Unsupported observed UI property") }
            case .readProperty:
                guard ["text", "value"].contains(operation.property), operation.binding == nil else { throw AutomationContractError.invalidPlan("Unsupported UI property") }
            default:
                guard operation.binding == nil, operation.property == nil else { throw AutomationContractError.invalidPlan("Ambiguous UI operation") }
            }
        }
    }
    public func approvedActions() throws -> [AutomationRunAuthority.Action] {
        try validate(phase: .setup)
        return [.activate] + operations.compactMap { operation in
            switch operation.kind {
            case .tap: return .tap
            case .fillBinding: return .fill(bindings[operation.binding!]!)
            case .scroll: return .swipe(operation.direction!)
            default: return nil
            }
        }
    }
    public func payload(scope: AutomationScope, phase: AutomationSegment.Phase, operationID: String, digestVersion: AutomationUIPayloadDigestVersion = .legacyV1) throws -> AutomationJSON {
        try scope.validate(); try validate(phase: phase)
        guard Self.identifier(operationID) else { throw AutomationContractError.invalidIdentity }
        let encoder = JSONEncoder()
        let operationJSON = try JSONDecoder().decode(AutomationJSON.self, from: encoder.encode(operations))
        var body: [String: AutomationJSON] = ["scope": try JSONDecoder().decode(AutomationJSON.self, from: encoder.encode(scope)),
            "operationId": .string(operationID), "phase": .string(phase.rawValue), "operations": operationJSON,
            "bindings": .object(bindings.mapValues(AutomationJSON.string)), "timeoutMs": .number(Double(timeoutMilliseconds))]
        if digestVersion == .lexicalV2 { body["digestVersion"] = .number(2) }
        body["payloadDigest"] = .string(AutomationArtifactRegistry.digest(try AutomationCanonicalJSON.encode(.object(body), legacyObjectKeyOrder: digestVersion == .legacyV1)))
        guard try encoder.encode(AutomationJSON.object(body)).count <= 1_047_552 else { throw AutomationContractError.invalidPlan("UI payload exceeds frame budget") }
        return .object(body)
    }
    private static func identifier(_ value: String) -> Bool {
        value.utf16.count <= 256 && value.range(of: #"^[A-Za-z0-9_.:-]+$"#, options: .regularExpression) != nil
    }
}

/// Missing envelope version is the historical JSON.stringify object ordering.
/// Explicit version-two envelopes sort every object key lexically.
/// Existing callers retain v1 until their verified runtime supports v2.
public enum AutomationUIPayloadDigestVersion: Equatable, Sendable { case legacyV1, lexicalV2 }

/// Canonical protocol numbers are exact safe integers; default keys use UTF-16 lexical order.
enum AutomationCanonicalJSON {
    static func encode(_ value: AutomationJSON, legacyObjectKeyOrder: Bool = false) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        func render(_ value: AutomationJSON) throws -> String {
            switch value {
            case .object(let fields):
                let keys = fields.keys.sorted { left, right in
                    if legacyObjectKeyOrder {
                        func index(_ key: String) -> UInt64? {
                            guard let value = UInt64(key), value < 4_294_967_295, String(value) == key else { return nil }
                            return value
                        }
                        switch (index(left), index(right)) {
                        case let (a?, b?): return a < b
                        case (_?, nil): return true
                        case (nil, _?): return false
                        default: break
                        }
                    }
                    return left.utf16.lexicographicallyPrecedes(right.utf16)
                }
                return "{" + (try keys.map { try render(.string($0)) + ":" + render(fields[$0]!) }).joined(separator: ",") + "}"
            case .array(let values): return "[" + (try values.map(render)).joined(separator: ",") + "]"
            case .number(let number):
                guard number.isFinite, number.rounded() == number, abs(number) <= 9_007_199_254_740_991 else { throw AutomationContractError.invalidIdentity }
                return String(Int64(number))
            default: return String(decoding: try encoder.encode(value), as: UTF8.self)
            }
        }
        return Data(try render(value).utf8)
    }
}
