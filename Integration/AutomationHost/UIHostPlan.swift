import Foundation

/// Portable wire contracts shared by the controller and generated XCTest bundle.
public struct UIHostValue: Codable, Equatable, Sendable {
    public var kind: String
    public var value: String?
    public var boolValue: Bool?
    public var typeId: String?
    public var properties: [String: UIHostValue]?
    public var items: [UIHostValue]?
    public var timeZone: String?
    public init(kind: String, value: String? = nil, boolValue: Bool? = nil, typeId: String? = nil,
                properties: [String: UIHostValue]? = nil, items: [UIHostValue]? = nil, timeZone: String? = nil) {
        self.kind = kind; self.value = value; self.boolValue = boolValue; self.typeId = typeId
        self.properties = properties; self.items = items; self.timeZone = timeZone
    }
}
public struct UIHostQuery: Codable, Equatable, Sendable {
    public var identifier: String?
    public var label: String?
    public var labelContains: String?
    public var elementType: String?
    public var index: Int?
    public init(identifier: String? = nil, label: String? = nil, labelContains: String? = nil, elementType: String? = nil, index: Int? = nil) {
        self.identifier = identifier; self.label = label; self.labelContains = labelContains
        self.elementType = elementType; self.index = index
    }
}
public struct UIHostSelection: Codable, Equatable, Sendable {
    public var typeID: String
    public var properties: [String: UIHostValue]
    public var identifier: String?
    public var expiresAt: Date?
    public init(typeID: String, properties: [String: UIHostValue], identifier: String? = nil, expiresAt: Date? = nil) {
        self.typeID = typeID; self.properties = properties; self.identifier = identifier; self.expiresAt = expiresAt
    }
    public func resolve(_ output: UIHostValue) throws -> UIHostValue {
        guard output.kind == "array", let items = output.items, items.count <= 1000,
              expiresAt.map({ $0 > Date() }) ?? true else { throw UIHostError.bindingUnavailable }
        var identities = Set<String>()
        for item in items {
            guard item.kind == "entity", item.typeId == typeID, let id = item.value,
                  identities.insert(id).inserted, item.properties != nil else { throw UIHostError.bindingUnavailable }
        }
        let matches = items.compactMap { item -> UIHostValue? in
            guard let actual = item.properties,
                  identifier.map({ $0 == item.value }) ?? properties.allSatisfy({ actual[$0.key] == $0.value }) else { return nil }
            return .init(kind: "entity", value: item.value, typeId: item.typeId)
        }
        guard matches.count == 1 else { throw UIHostError.bindingUnavailable }
        return matches[0]
    }
}
public struct UIHostBinding: Codable, Equatable, Sendable {
    public var producerSegmentID: String
    public var outputID: String
    public var destination: String
    public var name: String
    public var selection: UIHostSelection?
    public var parameterCodec: String?
    public init(producerSegmentID: String, outputID: String, destination: String, name: String, selection: UIHostSelection? = nil, parameterCodec: String? = nil) {
        self.producerSegmentID = producerSegmentID; self.outputID = outputID; self.destination = destination
        self.name = name; self.selection = selection
        self.parameterCodec = parameterCodec
    }
}
public struct UIHostCheck: Codable, Equatable, Sendable {
    public var outputID: String
    public var selection: UIHostSelection
    public var property: String
    public var expected: UIHostValue
    public init(outputID: String, selection: UIHostSelection, property: String, expected: UIHostValue) {
        self.outputID = outputID; self.selection = selection; self.property = property; self.expected = expected
    }
    public func validate(output: UIHostValue) throws {
        let entity = try selection.resolve(output)
        guard let record = output.items?.first(where: { $0.typeId == entity.typeId && $0.value == entity.value }),
              record.properties?[property] == expected else { throw UIHostError.assertionFailed }
    }
}
public struct UIHostStep: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case launch, tap, typeText, clearAndType, swipe, waitFor, assert, screenshot, invokeIntent, query, readProperty, checkFreshness }
    public var id: String
    public var segmentID: String
    public var kind: Kind
    public var query: UIHostQuery?
    public var text: String?
    public var binding: String?
    public var property: String?
    public var equals: UIHostValue?
    public var direction: String?
    public var timeout: Double?
    public var arguments: [String]?
    public var environment: [String: String]?
    public var operation: Data?
    public var inputBindings: [UIHostBinding]?
    public var setupChecks: [UIHostCheck]?
    public init(id: String, segmentID: String = "", kind: Kind, query: UIHostQuery? = nil, text: String? = nil,
                binding: String? = nil, property: String? = nil, equals: UIHostValue? = nil, direction: String? = nil,
                timeout: Double? = nil, arguments: [String]? = nil, environment: [String: String]? = nil,
                operation: Data? = nil, inputBindings: [UIHostBinding]? = nil) {
        self.id = id; self.segmentID = segmentID; self.kind = kind; self.query = query; self.text = text
        self.binding = binding; self.property = property; self.equals = equals; self.direction = direction
        self.timeout = timeout; self.arguments = arguments; self.environment = environment
        self.operation = operation; self.inputBindings = inputBindings
    }
}
public struct UIHostPlan: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var runID: String
    public var attemptID: String
    public var leaseGeneration: Int
    public var bundleID: String
    public var productDigest: String
    public var planDigest: String
    public var steps: [UIHostStep]
    public var bindings: [String: String]
    public var subjectSegmentID: String
    public var excludedEntityIDs: [String]
    public var freshnessBindings: [UIHostBinding]
    public init(runID: String, attemptID: String, leaseGeneration: Int, bundleID: String, productDigest: String,
                planDigest: String, steps: [UIHostStep], bindings: [String: String], subjectSegmentID: String = "", excludedEntityIDs: [String] = [], freshnessBindings: [UIHostBinding] = []) {
        self.runID = runID; self.attemptID = attemptID; self.leaseGeneration = leaseGeneration
        self.bundleID = bundleID; self.productDigest = productDigest; self.planDigest = planDigest
        self.steps = steps; self.bindings = bindings
        self.subjectSegmentID = subjectSegmentID; self.excludedEntityIDs = excludedEntityIDs
        self.freshnessBindings = freshnessBindings
    }
    public func validateFreshSubject(outputs: [String: [String: UIHostValue]]) throws {
        let excluded = Set(excludedEntityIDs)
        let subjectBindings = steps.filter { $0.segmentID == subjectSegmentID }.flatMap { $0.inputBindings ?? [] }
        for binding in subjectBindings + freshnessBindings {
                guard let selection = binding.selection else { continue }
                guard let output = outputs[binding.producerSegmentID]?[binding.outputID] else { throw UIHostError.bindingUnavailable }
                let entity = try selection.resolve(output)
                guard let type = entity.typeId, let id = entity.value,
                      !excluded.contains(type + ":" + id) else { throw UIHostError.reusedEntity }
        }
    }
    public func validate() throws {
        guard schemaVersion == 1, !runID.isEmpty, !attemptID.isEmpty, leaseGeneration > 0,
              !bundleID.isEmpty, (1...300).contains(steps.count), bindings.count <= 300,
              excludedEntityIDs.count <= 4096, Set(excludedEntityIDs).count == excludedEntityIDs.count,
              freshnessBindings.count <= 100,
              excludedEntityIDs.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 1281 }),
              [productDigest, planDigest].allSatisfy({ $0.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil }),
              Set(steps.map { $0.segmentID + "/" + $0.id }).count == steps.count else { throw UIHostError.invalidPlan }
        for step in steps {
            guard !step.id.isEmpty, !step.segmentID.isEmpty, (step.text?.utf16.count ?? 0) <= 32768,
                  (step.timeout ?? 10) > 0, (step.timeout ?? 10) <= 120,
                  (step.query?.index ?? 0) >= 0 else { throw UIHostError.invalidPlan }
            if step.kind == .invokeIntent || step.kind == .query {
                guard let data = step.operation, data.count <= 32768 else { throw UIHostError.invalidPlan }
            }
            if step.kind == .typeText || step.kind == .clearAndType {
                guard (step.text == nil) != (step.binding == nil) else { throw UIHostError.invalidPlan }
            }
        }
    }
}
public struct UIHostStepReceipt: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var runID: String
    public var attemptID: String
    public var leaseGeneration: Int
    public var bundleID: String
    public var productDigest: String
    public var planDigest: String
    public var stepIndex: Int
    public var segmentID: String
    public var stepID: String
    public var kind: UIHostStep.Kind
    public var dispatched: Bool
    public var completed: Bool
    public var value: UIHostValue?
    public var error: String?
    public init(plan: UIHostPlan, index: Int, dispatched: Bool, completed: Bool, value: UIHostValue? = nil, error: String? = nil) {
        runID = plan.runID; attemptID = plan.attemptID; leaseGeneration = plan.leaseGeneration
        bundleID = plan.bundleID; productDigest = plan.productDigest; planDigest = plan.planDigest
        stepIndex = index; segmentID = plan.steps[index].segmentID; stepID = plan.steps[index].id
        kind = plan.steps[index].kind; self.dispatched = dispatched; self.completed = completed
        self.value = value; self.error = error
    }
}
public enum UIHostError: Error { case invalidPlan, missingElement, ambiguousElement, assertionFailed, bindingUnavailable, timedOut, reusedEntity }
