import Foundation

/// Declared requirements are review data, never evidence of runtime conversion.
enum AutomationCodecRequirements {
    static func program(_ program: AutomationHostProgram) -> Set<String> {
        var families = Set<String>()
        for operation in program.operations where operation.kind == .invoke {
            for (name, value) in operation.parameters where value != .omission {
                if let codec = operation.parameterCodecs?[name] { families.insert(codec) }
                else if let family = family(value) { families.insert(family) }
            }
            if let codec = operation.resultCodec, codec != "noValue" { families.insert(codec) }
        }
        return Set(families.map { "apple.codec." + $0 })
    }
    static func segment(_ segment: AutomationSegment, plan: AutomationCase) -> Set<String> {
        var result = segment.hostProgram.map(program) ?? []
        for binding in segment.inputBindings ?? [] where binding.destination == .hostParameter {
            if let codec = binding.parameterCodec { result.insert("apple.codec." + codec) }
            let family: String?
            if binding.uniqueEntity != nil { family = "entity" }
            else if let producer = plan.setup.first(where: { $0.id == binding.producerSegmentID }) {
                if let output = producer.uiProgram?.operations.first(where: { $0.id == binding.outputID && $0.kind == .observeProperty }) {
                    family = ["text", "value"].contains(output.property) ? "text" : ["checked", "selected"].contains(output.property) ? "bool" : nil
                } else { family = producer.hostProgram?.operations.first(where: { $0.id == binding.outputID && $0.kind == .invoke })?.resultCodec }
            } else { family = nil }
            if let family, family != "noValue" { result.insert("apple.codec." + family) }
        }
        return result
    }
    static func validate(_ segment: AutomationSegment, plan: AutomationCase, capabilities: CapabilityProfile,
                         purpose: AutomationPlanValidationPurpose = .execution) throws {
        guard let program = segment.hostProgram else { return }
        if program.operations.contains(where: { operation in
            operation.kind == .invoke && operation.parameters.contains(where: { name, value in
                value == .null && operation.parameterCodecs?[name] == nil
            })
        }) { throw AutomationContractError.missingEvidence("Nullable input conversion lacks its frozen parameter family") }
        let derived = self.segment(segment, plan: plan)
        let codecs = Set(segment.requiredCapabilities.filter { $0.hasPrefix("apple.codec.") })
        guard derived.isSubset(of: codecs), purpose == .review || capabilities.supports(Array(codecs)) else {
            throw AutomationContractError.missingEvidence(codecs.contains("apple.codec.url")
                ? "URL conversion has not been verified for this app and target"
                : "Input and result conversion has not been verified for this app and target")
        }
    }
    static func declared(_ operation: AutomationHostProgram.Operation, action: ApplicationSurfaceCatalog.SystemAction,
                         bindings: [AutomationInputBinding]) -> Set<String> {
        Set(action.parameters.compactMap { parameter in
            let active = operation.parameters[parameter.name].map { $0 != .omission } ?? bindings.contains(where: { $0.name == parameter.name })
            return active ? parameter.family.map { "apple.codec." + $0 } : nil
        })
    }
    static func applying(to plan: AutomationCase, catalog: ApplicationSurfaceCatalog) -> AutomationCase {
        func decorate(_ segment: AutomationSegment) -> AutomationSegment {
            var value = segment
            // Freeze each nullable parameter's family; a capability list alone cannot bind it to a name.
            if var program = value.hostProgram {
                for index in program.operations.indices where program.operations[index].kind == .invoke {
                    let operation = program.operations[index]
                    guard let action = catalog.systemActions.first(where: { $0.id == operation.typeID }) else { continue }
                    for parameter in action.parameters where operation.parameters[parameter.name] == .null {
                        if let family = parameter.family, AutomationCodecRegistry.parameterFamilies.contains(family),
                           operation.parameterCodecs?[parameter.name] == nil {
                            program.operations[index].parameterCodecs = program.operations[index].parameterCodecs ?? [:]
                            program.operations[index].parameterCodecs?[parameter.name] = family
                        }
                    }
                }
                value.hostProgram = program
            }
            for index in value.inputBindings?.indices ?? 0..<0 {
                guard let binding = value.inputBindings?[index], binding.destination == .hostParameter,
                      binding.parameterCodec == nil, binding.uniqueEntity == nil,
                      let operation = value.hostProgram?.operations.first(where: { $0.id == binding.operationID }), operation.kind == .invoke else { continue }
                let actions = catalog.systemActions.filter { $0.id == operation.typeID }
                guard actions.count == 1, let family = actions[0].parameters.first(where: { $0.name == binding.name })?.family,
                      AutomationInputResolver.deferredParameterCodecs.contains(family) else { continue }
                value.inputBindings?[index].parameterCodec = family
            }
            var requirements = self.segment(value, plan: plan)
            for operation in segment.hostProgram?.operations ?? [] where operation.kind == .invoke {
                if let action = catalog.systemActions.first(where: { $0.id == operation.typeID }) {
                    let bindings = (segment.inputBindings ?? []).filter { $0.destination == .hostParameter && $0.operationID == operation.id }
                    requirements.formUnion(declared(operation, action: action, bindings: bindings))
                }
            }
            value.requiredCapabilities += requirements.subtracting(value.requiredCapabilities).sorted()
            return value
        }
        var value = plan
        value.setup = plan.setup.map(decorate); value.execution = decorate(plan.execution)
        value.observations = plan.observations.map(decorate); value.cleanup = plan.cleanup.map(decorate)
        return value
    }
    private static func family(_ value: AutomationValue) -> String? {
        switch value {
        case .text: "text"
        case .bool: "bool"
        case .integer: "integer"
        case .decimal: "decimal"
        case .date: "date"
        case .enumeration: "enum"
        case .entity: "entity"
        case .array: "textArray" // Legacy unannotated arrays have only this frozen host codec.
        default: nil
        }
    }
}

public enum AutomationPlanValidationPurpose: Sendable { case execution, review }
