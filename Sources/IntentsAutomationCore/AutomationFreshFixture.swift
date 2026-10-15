import Foundation

/// Data proposes a checked binding; decoding it grants no fixture authority.
public struct AutomationFreshFixtureBinding: Codable, Equatable, Sendable {
    public let producerSegmentID: String
    public let outputID: String
    public let selection: AutomationEntitySelection
    public init(producerSegmentID: String, outputID: String, selection: AutomationEntitySelection) {
        self.producerSegmentID = producerSegmentID; self.outputID = outputID; self.selection = selection
    }
}

/// Stateless validation of deterministic fresh-record setup and recorded identities.
public enum AutomationFreshFixtureEvidence {
    static func requiresFreshIdentities(_ plan: AutomationCase) -> Bool {
        (plan.setupChecks ?? []).contains { $0.entityProperty?.selection.attemptProperties?.isEmpty == false }
    }

    static func recordedIdentities(report: AutomationAttemptReport, plan: AutomationCase) throws -> Set<String> {
        guard let runID = report.receipts.first?.scope.runId else { throw AutomationFixtureFreshnessError.invalidFixture }
        let receipts = report.receipts.filter { receipt in plan.setup.contains(where: { $0.id == receipt.segmentID }) }
        return try identitiesBeforeSubject(receipts: receipts, plan: plan, runID: runID, attemptID: report.attemptID)
    }

    static func identitiesBeforeSubject(receipts: [AutomationSegmentReceipt], plan: AutomationCase,
                                        runID: String, attemptID: String) throws -> Set<String> {
        var bindings: [AutomationFreshFixtureBinding] = []
        for check in plan.setupChecks ?? [] {
            guard let property = check.entityProperty, property.selection.attemptProperties?.isEmpty == false else { continue }
            let binding = AutomationFreshFixtureBinding(producerSegmentID: check.observationID, outputID: property.operationID, selection: property.selection)
            if !bindings.contains(binding) { bindings.append(binding) }
        }
        guard (1...10).contains(bindings.count) else { throw AutomationFixtureFreshnessError.invalidFixture }
        try validateBindings(bindings, plan: plan)
        return try identities(bindings: bindings, receipts: receipts, plan: plan, runID: runID, attemptID: attemptID)
    }

    static func dispatchedIdentities(report: AutomationAttemptReport, plan: AutomationCase) throws -> Set<String> {
        guard requiresFreshIdentities(plan), report.result.subjectDispatched || report.result.subjectDispatchUncertain else { return [] }
        return try recordedIdentities(report: report, plan: plan)
    }

    fileprivate static func identities(bindings: [AutomationFreshFixtureBinding], receipts: [AutomationSegmentReceipt],
                                   plan: AutomationCase, runID: String, attemptID: String) throws -> Set<String> {
        guard receipts.map(\.segmentID) == plan.setup.map(\.id),
              receipts.allSatisfy({ $0.dispatched && $0.completed && $0.app == plan.app && $0.target == plan.target &&
                  $0.environmentID == plan.environmentID && $0.scope.runId == runID && $0.scope.attemptId == attemptID &&
                  $0.scope.segmentId == $0.segmentID }) else { throw AutomationFixtureFreshnessError.invalidFixture }
        var identities: Set<String> = []
        for binding in bindings {
            guard let setup = plan.setup.first(where: { $0.id == binding.producerSegmentID }),
                  let query = setup.hostProgram?.operations.first(where: { $0.id == binding.outputID }),
                  let receipt = receipts.first(where: { $0.segmentID == setup.id }), receipt.route == setup.kind,
                  AutomationFixtureValidator.validates(receipt: receipt, segment: setup, plan: plan, runID: runID, attemptID: attemptID),
                  let output = receipt.verifiedOutputs?[binding.outputID],
                  case .entity(let type, let id) = try binding.selection.resolve(output, query: query, attemptID: attemptID),
                  identities.insert(type + ":" + id).inserted else { throw AutomationFixtureFreshnessError.invalidFixture }
        }
        return identities
    }

    static func validateBindings(_ bindings: [AutomationFreshFixtureBinding], plan: AutomationCase) throws {
        let segments = plan.setup + [plan.execution] + plan.observations + plan.cleanup
        let checks = plan.setupChecks ?? []
        guard !segments.contains(where: { $0.effects.contains(.externalWrite) }), plan.cleanup.isEmpty, !checks.isEmpty,
              plan.setup.contains(where: { $0.kind == .ui && $0.effects.contains(.fixtureWrite) }),
              plan.setup.allSatisfy({ $0.kind == .ui || ($0.kind == .systemQuery && $0.effects.isSubset(of: [.observe, .navigate])) }),
              plan.observations.allSatisfy({ $0.effects.isSubset(of: [.observe, .navigate]) }),
              checks.allSatisfy({ check in bindings.contains(where: {
                  $0.producerSegmentID == check.observationID && $0.outputID == check.entityProperty?.operationID &&
                  $0.selection == check.entityProperty?.selection
              }) }) else { throw AutomationContractError.missingEvidence("Every checked record must come from the frozen setup") }
        for binding in bindings {
            guard let setup = plan.setup.first(where: { $0.id == binding.producerSegmentID }), setup.kind == .systemQuery,
                  setup.effects.isSubset(of: [.observe, .navigate]), let query = setup.hostProgram?.operations.first(where: { $0.id == binding.outputID }),
                  checks.contains(where: { $0.observationID == setup.id && $0.entityProperty?.operationID == query.id && $0.entityProperty?.selection == binding.selection }),
                  plan.setup.prefix(while: { $0.id != setup.id }).contains(where: { $0.kind == .ui && $0.effects.contains(.fixtureWrite) }) else {
                throw AutomationContractError.missingEvidence("Fresh binding needs a prior UI write and an independent fixture check")
            }
            try binding.selection.validate(query: query)
        }
        if !plan.execution.effects.isSubset(of: [.observe, .navigate]) {
            let inputs = plan.execution.inputBindings ?? []
            guard plan.execution.kind == .systemIntent, !inputs.isEmpty, plan.execution.inputs.isEmpty,
                  let operations = plan.execution.hostProgram?.operations, operations.count == 1,
                  let operation = operations.first, operation.kind == .invoke, operation.parameters.isEmpty,
                  inputs.allSatisfy({ input in
                      input.destination == .hostParameter && input.operationID == operation.id && input.uniqueEntity != nil && bindings.contains(where: { binding in
                          binding.producerSegmentID == input.producerSegmentID && binding.outputID == input.outputID &&
                          binding.selection.typeID == input.uniqueEntity?.typeID &&
                          binding.selection.attemptProperties == input.uniqueEntity?.attemptProperties &&
                          binding.selection.matchingProperties.allSatisfy({ input.uniqueEntity?.matchingProperties[$0.key] == $0.value })
                      })
                  }) else { throw AutomationContractError.missingEvidence("Repeated mutation needs exclusively fresh checked entity bindings") }
        }
    }

}

enum AutomationFixtureFreshnessError: Error { case invalidFixture }
