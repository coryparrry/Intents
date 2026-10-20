import Foundation
import IntentsAutomationUIHostContracts

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
        public enum Kind: String, Codable, Sendable { case tap, fillBinding, readProperty, observeProperty, assertEndpoint, locate, scroll }
        public var kind: Kind
        public var id: String
        public var locator: Locator?
        public var binding: String?
        public var property: String?
        public var direction: String?
        public init(id: String, kind: Kind, locator: Locator? = nil, binding: String? = nil, property: String? = nil, direction: String? = nil) {
            self.id = id; self.kind = kind; self.locator = locator; self.binding = binding; self.property = property; self.direction = direction
        }
    }
    public var operations: [Operation]
    public var bindings: [String: String]
    public var timeoutMilliseconds: Int
    public var steps: [UIHostStep]?
    public init(operations: [Operation] = [], bindings: [String: String] = [:], timeoutMilliseconds: Int = 120_000, steps: [UIHostStep]? = nil) {
        self.operations = operations; self.bindings = bindings; self.timeoutMilliseconds = timeoutMilliseconds
        self.steps = steps
    }
    public func validate(phase: AutomationSegment.Phase) throws {
        if let steps {
            guard operations.isEmpty, (1...30).contains(steps.count), bindings.count <= 30,
                  (100...120_000).contains(timeoutMilliseconds), Set(steps.map(\.id)).count == steps.count,
                  bindings.allSatisfy({ Self.identifier($0.key) && $0.value.utf16.count <= 32768 }) else {
                throw AutomationContractError.invalidPlan("Malformed direct XCUITest program")
            }
            let supported: [UIHostStep.Kind] = [.launch, .tap, .typeText, .clearAndType, .swipe, .waitFor, .assert, .screenshot, .readProperty, .readHierarchy]
            for step in steps {
                if step.kind == .readHierarchy { try step.validateHierarchyRead() }
                guard Self.identifier(step.id), supported.contains(step.kind), step.operation == nil,
                      step.inputBindings == nil, step.setupChecks == nil,
                      (step.text?.utf16.count ?? 0) <= 32768,
                      [step.query?.identifier, step.query?.label, step.query?.labelContains, step.query?.elementType].compactMap({ $0 }).allSatisfy({ $0.utf16.count <= 1024 && !$0.contains("\0") }),
                      (step.timeout ?? 10) > 0, (step.timeout ?? 10) <= 120 else { throw AutomationContractError.invalidPlan("Unsupported direct UI step") }
                if [.typeText, .clearAndType].contains(step.kind) {
                    guard phase != .observe, (step.text == nil) != (step.binding == nil),
                          step.binding.map({ bindings[$0] != nil }) ?? true else { throw AutomationContractError.invalidPlan("Missing direct UI fill input") }
                }
                if [.tap, .typeText, .clearAndType, .waitFor, .assert, .readProperty].contains(step.kind) {
                    guard let query = step.query, query.index.map({ $0 >= 0 }) ?? true,
                          [query.identifier, query.label, query.labelContains, query.elementType].contains(where: { $0?.isEmpty == false }) else { throw AutomationContractError.invalidPlan("Missing direct UI query") }
                }
                if step.kind == .swipe, !["up", "down", "left", "right"].contains(step.direction) { throw AutomationContractError.invalidPlan("Invalid direct UI swipe") }
                if step.kind == .waitFor, !["exists", "hittable", "absent"].contains(step.property) { throw AutomationContractError.invalidPlan("Invalid direct UI wait") }
                if step.kind == .readProperty, !["label", "text", "value", "exists", "selected", "checked"].contains(step.property) { throw AutomationContractError.invalidPlan("Invalid direct UI property") }
                if let type = step.query?.elementType, !["any", "button", "textField", "textbox", "secureTextField", "searchField", "searchbox", "textView", "staticText", "switch", "cell", "window", "other"].contains(type) { throw AutomationContractError.invalidPlan("Invalid direct UI element type") }
                if step.kind == .launch {
                    guard (step.arguments?.count ?? 0) <= 100, (step.environment?.count ?? 0) <= 32,
                          (step.arguments ?? []).allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 32768 }),
                          (step.environment ?? [:]).allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") && $0.value.utf8.count <= 32768 }) else {
                        throw AutomationContractError.invalidPlan("Invalid direct UI launch inputs")
                    }
                }
                if step.kind == .assert {
                    guard ["label", "value", "exists", "selected"].contains(step.property), let expected = step.equals,
                          (["exists", "selected"].contains(step.property) ? expected.kind == "bool" && expected.boolValue != nil : expected.kind == "text" && expected.value != nil) else {
                        throw AutomationContractError.invalidPlan("Invalid direct UI assertion")
                    }
                }
            }
            return
        }
        guard (1...30).contains(operations.count), bindings.count <= 30, (100...120_000).contains(timeoutMilliseconds),
              Set(operations.map(\.id)).count == operations.count,
              bindings.allSatisfy({ Self.identifier($0.key) && $0.value.utf16.count <= 32768 }) else {
            throw AutomationContractError.invalidPlan("Malformed UI program")
        }
        for operation in operations {
            guard Self.identifier(operation.id) else { throw AutomationContractError.invalidIdentity }
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
    private static func identifier(_ value: String) -> Bool {
        value.utf16.count <= 256 && value.range(of: #"^[A-Za-z0-9_.:-]+$"#, options: .regularExpression) != nil
    }
}

/// Canonical protocol numbers are exact safe integers; default keys use UTF-16 lexical order.
enum AutomationCanonicalJSON {
    static func encode(_ value: AutomationJSON) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        func render(_ value: AutomationJSON) throws -> String {
            switch value {
            case .object(let fields):
                let keys = fields.keys.sorted { left, right in
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
