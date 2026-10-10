import Foundation

/// A positive selection within this real query result, never a claim of global query completeness.
/// Ownership/account fields must be supplied as actual declared property predicates in the frozen plan.
public struct AutomationEntitySelection: Codable, Equatable, Sendable {
    public var typeID: String
    public var matchingProperties: [String: AutomationValue]
    public var attemptProperties: [String: String]?
    public init(typeID: String, matchingProperties: [String: AutomationValue], attemptProperties: [String: String]? = nil) {
        self.typeID = typeID; self.matchingProperties = matchingProperties; self.attemptProperties = attemptProperties
    }
    func validate(query: AutomationHostProgram.Operation) throws {
        guard query.kind == .query, query.typeID == typeID, AutomationHostProgram.identifier(typeID),
              (1...10).contains(matchingProperties.count + (attemptProperties?.count ?? 0)),
              Set(matchingProperties.keys).isDisjoint(with: Set((attemptProperties ?? [:]).keys)) else {
            throw AutomationContractError.invalidPlan("Entity selection requires declared distinguishing properties")
        }
        for (name, prefix) in attemptProperties ?? [:] {
            guard AutomationHostProgram.identifier(name), query.properties?[name] == "text" else { throw AutomationContractError.invalidPlan("Attempt name requires a declared text property") }
            try AutomationAttemptText.validatePrefix(prefix)
        }
        for (name, value) in matchingProperties {
            try value.validate()
            guard AutomationHostProgram.identifier(name), Self.matchesCodec(value, query.properties?[name]) else {
                throw AutomationContractError.invalidPlan("Entity selection property has no matching declared codec")
            }
        }
    }
    func resolve(_ output: AutomationValue, query: AutomationHostProgram.Operation, attemptID: String? = nil) throws -> AutomationValue {
        try validate(query: query)
        try Self.validateQueryOutput(output, query: query)
        guard case .array(let records) = output else { throw AutomationInputBindingError.inputUnavailable }
        var expected = matchingProperties
        for (name, prefix) in attemptProperties ?? [:] {
            guard let attemptID else { throw AutomationInputBindingError.inputUnavailable }
            expected[name] = .text(try AutomationAttemptText.value(prefix: prefix, attemptID: attemptID))
        }
        let matches = records.compactMap { record -> AutomationValue? in
            guard case .object(let fields) = record, case .object(let properties) = fields["properties"],
                  expected.allSatisfy({ properties[$0.key] == $0.value }) else { return nil }
            return fields["entity"]
        }
        guard matches.count == 1 else { throw AutomationInputBindingError.inputUnavailable }
        return matches[0]
    }
    static func validateQueryOutput(_ output: AutomationValue, query: AutomationHostProgram.Operation) throws {
        try output.validate()
        guard case .array(let records) = output, records.count <= 1000 else { throw AutomationInputBindingError.inputUnavailable }
        var identities = Set<String>()
        let declared = query.properties ?? [:]
        for record in records {
            guard case .object(let fields) = record, Set(fields.keys) == ["entity", "properties"],
                  case .entity(let type, let id) = fields["entity"], type == query.typeID, identities.insert(id).inserted,
                  query.queryIDs.map({ $0.contains(id) }) ?? true,
                  case .object(let properties) = fields["properties"], Set(properties.keys) == Set(declared.keys),
                  properties.allSatisfy({ Self.matchesCodec($0.value, declared[$0.key]) }) else {
                throw AutomationInputBindingError.inputUnavailable
            }
        }
    }
    static func matchesCodec(_ value: AutomationValue, _ codec: String?) -> Bool {
        switch (value, codec) {
        case (.text, "text"), (.bool, "bool"): true
        case (.integer(let value), "integer"): Int64(value) != nil
        default: false
        }
    }
}
