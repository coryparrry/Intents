import Foundation

/// A positive property check on one real query-returned entity. This never proves
/// global query completeness, absence, persistence, or an invented entity ID.
public struct AutomationEntityPropertyPredicate: Codable, Equatable, Sendable {
    public var operationID: String
    public var selection: AutomationEntitySelection
    public var property: String
    public init(operationID: String, selection: AutomationEntitySelection, property: String) {
        self.operationID = operationID; self.selection = selection; self.property = property
    }
    func validate(query: AutomationHostProgram.Operation, expected: AutomationValue) throws {
        guard operationID == query.id, AutomationHostProgram.identifier(property),
              selection.matchingProperties[property] == nil, selection.attemptProperties?[property] == nil,
              AutomationEntitySelection.matchesCodec(expected, query.properties?[property]) else {
            throw AutomationContractError.invalidPlan("Entity property expectation has no declared scalar codec")
        }
        try selection.validate(query: query)
        try expected.validate()
    }
    func value(queryResult: AutomationValue, query: AutomationHostProgram.Operation, attemptID: String? = nil) throws -> AutomationValue {
        try selection.validate(query: query)
        let entity = try selection.resolve(queryResult, query: query, attemptID: attemptID)
        guard case .array(let records) = queryResult else { throw AutomationInputBindingError.inputUnavailable }
        for record in records {
            if case .object(let fields) = record, fields["entity"] == entity,
               case .object(let properties) = fields["properties"], let value = properties[property] { return value }
        }
        throw AutomationInputBindingError.inputUnavailable
    }
    func value(observation: AutomationObservation, segment: AutomationSegment) throws -> AutomationValue {
        guard segment.kind == .systemQuery, let program = segment.hostProgram,
              let query = program.operations.first(where: { $0.id == operationID }) else { throw AutomationInputBindingError.inputUnavailable }
        let result: AutomationValue
        if program.operations.count == 1 { result = observation.value }
        else if case .object(let values) = observation.value, let value = values[operationID] { result = value }
        else { throw AutomationInputBindingError.inputUnavailable }
        return try value(queryResult: result, query: query, attemptID: observation.attemptID)
    }
}

enum AutomationRequirementValidator {
    static func validate(plan: AutomationCase) throws {
        let setupChecks = plan.setupChecks ?? []
        guard setupChecks.count <= 30, plan.requirements.count <= 100 else { throw AutomationContractError.invalidPlan("Too many case checks") }
        for (checks, segments, setup) in [(setupChecks, plan.setup, true), (plan.requirements, plan.observations, false)] {
            guard Set(checks.map { $0.checkID ?? $0.observationID }).count == checks.count else { throw AutomationContractError.invalidPlan("Duplicate case check identity") }
            for check in checks {
                try check.expected.validate()
                guard !check.justification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      check.checkID == nil || AutomationHostProgram.identifier(check.checkID!),
                      let segment = segments.first(where: { $0.id == check.observationID }) else {
                    throw AutomationContractError.invalidPlan("Case check has no justified independent source")
                }
                if let predicate = check.entityProperty {
                    guard check.checkID != nil, check.proof == .appState, segment.kind == .systemQuery,
                          let query = segment.hostProgram?.operations.first(where: { $0.id == predicate.operationID }) else {
                        throw AutomationContractError.invalidPlan("Entity property checks need named real query app-state evidence")
                    }
                    try predicate.validate(query: query, expected: check.expected)
                    if setup, let index = plan.setup.firstIndex(where: { $0.id == segment.id }) {
                        // A later UI action or intent may invalidate this precondition.
                        // Only declared read-only query segments may follow the check.
                        guard plan.setup.dropFirst(index + 1).allSatisfy({
                            $0.kind == .systemQuery && $0.effects.isSubset(of: [.observe])
                        }) else { throw AutomationContractError.invalidPlan("Fixture queries must follow all mutating setup steps") }
                    }
                } else if setup { throw AutomationContractError.invalidPlan("Setup checks require qualified entity-property projection") }
            }
        }
    }
}

enum AutomationFixtureValidator {
    static func validates(receipt: AutomationSegmentReceipt, segment: AutomationSegment, plan: AutomationCase,
                          runID: String, attemptID: String) -> Bool {
        let checks = (plan.setupChecks ?? []).filter { $0.observationID == segment.id }
        guard !checks.isEmpty else { return true }
        guard receipt.app == plan.app, receipt.target == plan.target, receipt.environmentID == plan.environmentID,
              receipt.scope.runId == runID, receipt.scope.attemptId == attemptID,
              receipt.scope.segmentId == segment.id, receipt.segmentID == segment.id, receipt.route == .systemQuery,
              receipt.dispatched, receipt.completed else { return false }
        return checks.allSatisfy { check in
            guard let predicate = check.entityProperty,
                  let query = segment.hostProgram?.operations.first(where: { $0.id == predicate.operationID }),
                  let value = receipt.verifiedOutputs?[predicate.operationID],
                  let actual = try? predicate.value(queryResult: value, query: query, attemptID: attemptID) else { return false }
            return actual == check.expected
        }
    }
}
