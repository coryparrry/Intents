import Foundation
@_exported import IntentsAutomationUIHostContracts

public enum AutomationXCUITestPlan {
    /// Independent storage reads run only after the one native host has drained.
    /// Their omission from host steps never changes the approved full-case digest.
    static func durableObservationSuffix(plan: AutomationCase) throws -> [AutomationSegment] {
        let segments = plan.setup + [plan.execution] + plan.observations + plan.cleanup
        guard segments.allSatisfy({ ($0.kind == .storageRead) == ($0.durableStateReader != nil) }) else {
            throw AutomationContractError.invalidPlan("A storage route requires its independent reader")
        }
        guard segments.contains(where: { $0.kind == .storageRead }) else { return [] }
        guard plan.target.kind == .nativeMac, plan.cleanup.isEmpty,
              !plan.setup.contains(where: { $0.kind == .storageRead }), plan.execution.kind != .storageRead,
              let start = plan.observations.firstIndex(where: { $0.kind == .storageRead }),
              plan.observations[start...].allSatisfy({ $0.kind == .storageRead && $0.phase == .observe }) else {
            throw AutomationContractError.invalidPlan("Independent storage reads require a final Mac observation phase without cleanup")
        }
        let suffix = Array(plan.observations[start...])
        for segment in suffix { try segment.durableStateReader!.validate(plan: plan, segment: segment) }
        return suffix
    }

    static func implicitMacHostActivationSegmentID(plan: AutomationCase, approval: RunApproval) -> String? {
        guard plan.target.kind == .nativeMac, approval.effects.contains(.navigate) else { return nil }
        for segment in plan.setup + [plan.execution] + plan.observations + plan.cleanup where segment.kind != .storageRead {
            if let program = segment.uiProgram {
                if segment.lifecycle != .noActivation || program.steps?.contains(where: { $0.kind == .launch }) == true { return nil }
            } else if segment.hostProgram != nil, segment.lifecycle != .noActivation {
                return segment.lifecycle == .persistedStateAcrossSegments ? segment.id : nil
            }
        }
        return nil
    }

    static func entityFreshnessSegmentID(plan: AutomationCase) -> String? {
        guard let setup = plan.setup.last,
              (plan.setupChecks ?? []).contains(where: { $0.entityProperty != nil }) ||
              plan.execution.inputBindings?.contains(where: { $0.uniqueEntity != nil }) == true else { return nil }
        return setup.id
    }

    public static func assemble(plan: AutomationCase, approval: RunApproval, attemptID: String, leaseGeneration: Int, excludedEntityIDs: Set<String> = []) throws -> UIHostPlan {
        guard approval.app == plan.app, approval.target == plan.target, approval.environmentID == plan.environmentID,
              approval.approvedCaseDigest == (try AutomationFrozenCase.planDigest(plan)), let digest = plan.app.productDigest else {
            throw AutomationContractError.conflictingOperation
        }
        _ = try durableObservationSuffix(plan: plan)
        try AutomationInputResolver.validate(plan: plan)
        let activationSegmentID = implicitMacHostActivationSegmentID(plan: plan, approval: approval)
        var steps: [UIHostStep] = [], bindings: [String: String] = [:], launched = false, hasUI = false
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for segment in plan.setup + [plan.execution] + plan.observations + plan.cleanup {
            if segment.kind == .storageRead { continue }
            try segment.validateObservationOnly()
            let inputs = segment.inputBindings ?? []
            let sharedBindings = try inputs.map { input in
                UIHostBinding(producerSegmentID: input.producerSegmentID, outputID: input.outputID,
                              destination: input.destination.rawValue, name: input.name,
                              selection: try input.uniqueEntity.map { try selection($0, attemptID: attemptID) }, parameterCodec: input.parameterCodec)
            }
            if var program = segment.uiProgram {
                hasUI = true
                for (name, prefix) in segment.attemptTextBindings ?? [:] {
                    program.bindings[name] = try AutomationAttemptText.value(prefix: prefix, attemptID: attemptID)
                }
                for input in inputs where input.destination == .uiBinding { program.bindings[input.name] = "" }
                try program.validate(phase: segment.phase)
                if !launched, segment.lifecycle != .noActivation, program.steps?.first?.kind != .launch {
                    steps.append(.init(id: "__xcuitest_launch", segmentID: segment.id, kind: .launch)); launched = true
                }
                for (name, value) in program.bindings { bindings[segment.id + "/" + name] = value }
                if let direct = program.steps {
                    guard segment.lifecycle != .noActivation || !direct.contains(where: { $0.kind == .launch }) else {
                        throw AutomationContractError.invalidPlan("A no-activation segment cannot launch the app")
                    }
                    for var step in direct {
                        step.segmentID = segment.id
                        step.inputBindings = sharedBindings.filter { $0.destination == "uiBinding" }
                        if step.timeout == nil { step.timeout = Double(program.timeoutMilliseconds) / 1000 }
                        if step.kind == .launch { launched = true }
                        steps.append(step)
                    }
                } else { for operation in program.operations {
                    var query: UIHostQuery?
                    if let locator = operation.locator {
                        switch locator.kind {
                        case .testId: query = .init(identifier: locator.value)
                        case .label: query = .init(label: locator.value, elementType: locator.role == .button ? "button" : nil)
                        case .role: query = .init(elementType: locator.value)
                        }
                    }
                    let kind: UIHostStep.Kind
                    var property = operation.property
                    switch operation.kind {
                    case .tap: kind = .tap
                    case .fillBinding: kind = .clearAndType
                    case .readProperty, .observeProperty: kind = .readProperty
                    case .scroll: kind = .swipe
                    case .locate, .assertEndpoint: kind = .waitFor; property = "exists"
                    }
                    steps.append(.init(id: operation.id, segmentID: segment.id, kind: kind, query: query,
                                       binding: operation.binding, property: property, direction: operation.direction,
                                       timeout: Double(program.timeoutMilliseconds) / 1000,
                                       inputBindings: sharedBindings.filter { $0.destination == "uiBinding" }))
                }
                }
            } else if var program = segment.hostProgram {
                guard !program.usesFiles else { throw AutomationContractError.missingEvidence("Mixed XCUITest file transfer is not supported") }
                if plan.target.kind == .nativeMac, !launched, segment.lifecycle != .noActivation {
                    guard !segment.effects.contains(.navigate) || approval.effects.contains(.navigate) else {
                        throw AutomationContractError.invalidPlan("Mac host activation needs approved navigation and persisted-state lifecycle")
                    }
                    if approval.effects.contains(.navigate) {
                        guard segment.lifecycle == .persistedStateAcrossSegments, activationSegmentID == segment.id else {
                            throw AutomationContractError.invalidPlan("Mac host activation needs approved navigation and persisted-state lifecycle")
                        }
                        // Activation is an approved plan prerequisite; query domain effects stay read-only.
                        steps.append(.init(id: "__xcuitest_launch", segmentID: segment.id, kind: .launch))
                        launched = true
                    }
                }
                for index in program.operations.indices {
                    if inputs.contains(where: { $0.destination == .hostQueryIDs && $0.operationID == program.operations[index].id }) {
                        // This selector is replaced in the test by the preceding exact query result.
                        program.operations[index].queryIDs = ["__intents_runtime_bound_entity__"]
                    }
                    if let prefix = program.operations[index].attemptQueryPrefix {
                        program.operations[index].queryText = try AutomationAttemptText.value(prefix: prefix, attemptID: attemptID)
                        program.operations[index].attemptQueryPrefix = nil
                    }
                }
                let scope = AutomationScope(runID: approval.runID, attemptID: attemptID, segmentID: segment.id, leaseGeneration: leaseGeneration)
                let payload = try program.payload(scope: scope, app: plan.app, route: segment.kind, phase: segment.phase)
                guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                      let operations = object["operations"] as? [[String: Any]], operations.count == program.operations.count else { throw AutomationContractError.invalidPlan("Missing host operations") }
                for (operation, fields) in zip(program.operations, operations) {
                    let active = zip(inputs, sharedBindings).filter { $0.0.operationID == operation.id }.map(\.1)
                    steps.append(.init(id: operation.id, segmentID: segment.id, kind: operation.kind == .invoke ? .invokeIntent : .query,
                                       operation: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), inputBindings: active))
                }
            } else { throw AutomationContractError.missingEvidence("Segment has no qualified XCUITest program") }
            let checks = (plan.setupChecks ?? []).filter { $0.observationID == segment.id }
            if !checks.isEmpty {
                guard !steps.isEmpty else { throw AutomationContractError.invalidPlan("Setup check has no steps") }
                steps[steps.count - 1].setupChecks = try checks.map { check in
                    guard let predicate = check.entityProperty else { throw AutomationContractError.invalidPlan("Setup check requires entity projection") }
                    return UIHostCheck(outputID: predicate.operationID, selection: try selection(predicate.selection, attemptID: attemptID),
                                       property: predicate.property, expected: try value(check.expected))
                }
            }
        }
        let freshnessBindings = try (plan.setupChecks ?? []).compactMap { check -> UIHostBinding? in
            guard let predicate = check.entityProperty else { return nil }
            return .init(producerSegmentID: check.observationID, outputID: predicate.operationID, destination: "freshness",
                         name: check.checkID ?? check.observationID, selection: try selection(predicate.selection, attemptID: attemptID))
        }
        if let setupID = entityFreshnessSegmentID(plan: plan),
           let subjectIndex = steps.firstIndex(where: { $0.segmentID == plan.execution.id }) {
            steps.insert(.init(id: "__xcuitest_freshness", segmentID: setupID, kind: .checkFreshness), at: subjectIndex)
        }
        if hasUI, let last = steps.last {
            steps.append(.init(id: "__xcuitest_final_screenshot", segmentID: last.segmentID, kind: .screenshot))
        }
        let result = UIHostPlan(runID: approval.runID, attemptID: attemptID, leaseGeneration: leaseGeneration,
                                bundleID: plan.app.bundleID, productDigest: digest,
                                planDigest: try AutomationFrozenCase.planDigest(plan), steps: steps, bindings: bindings,
                                subjectSegmentID: plan.execution.id, excludedEntityIDs: excludedEntityIDs.sorted(), freshnessBindings: freshnessBindings)
        try result.validate()
        let uiActions = steps.filter { [.launch, .tap, .typeText, .clearAndType, .swipe].contains($0.kind) }.count
        guard uiActions <= plan.budget.uiActions, steps.filter({ $0.segmentID == plan.execution.id }).count <= plan.budget.subjectOperations,
              steps.count <= approval.maximumActions else {
            throw AutomationContractError.invalidPlan("XCUITest program exceeds its approved action budget")
        }
        guard try encoder.encode(result).count <= 32768 else { throw AutomationContractError.invalidPlan("UI plan exceeds XCTest environment budget") }
        return result
    }
    private static func selection(_ selection: AutomationEntitySelection, attemptID: String) throws -> UIHostSelection {
        var properties = try selection.matchingProperties.mapValues(value)
        for (name, prefix) in selection.attemptProperties ?? [:] {
            properties[name] = .init(kind: "text", value: try AutomationAttemptText.value(prefix: prefix, attemptID: attemptID))
        }
        return .init(typeID: selection.typeID, properties: properties, identifier: selection.expectedIdentifier, expiresAt: selection.expiresAt)
    }
    private static func value(_ value: AutomationValue) throws -> UIHostValue {
        try JSONDecoder().decode(UIHostValue.self, from: JSONEncoder().encode(AutomationHostProgram.hostInput(value)))
    }
}
