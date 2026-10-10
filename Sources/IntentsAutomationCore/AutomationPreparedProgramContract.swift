import Foundation

/// Frozen programs must use the selected product's declarations, including their deferred inputs.
enum AutomationPreparedProgramContract {
    static func validate(_ plan: AutomationCase, catalog: ApplicationSurfaceCatalog) throws {
        guard plan.app == catalog.app else { throw AutomationContractError.conflictingOperation }
        try AutomationInputResolver.validate(plan: plan)
        try AutomationURLProgramContract.validate(plan, catalog: catalog)
        for segment in plan.setup + [plan.execution] + plan.observations + plan.cleanup {
            for operation in segment.hostProgram?.operations ?? [] {
                if operation.kind == .query {
                    try validateQuery(operation, catalog: catalog)
                    continue
                }
                let actions = catalog.systemActions.filter { $0.id == operation.typeID }
                guard actions.count == 1, let action = actions.first, action.compiled, action.parametersComplete,
                      Set(action.parameters.map(\.name)).count == action.parameters.count,
                      Set(operation.parameters.keys).isSubset(of: Set(action.parameters.map(\.name))) else { throw missing() }
                let bindings = (segment.inputBindings ?? []).filter { $0.destination == .hostParameter && $0.operationID == operation.id }
                guard Set(bindings.map(\.name)).isSubset(of: Set(action.parameters.map(\.name))) else { throw missing() }
                for (name, codec) in operation.parameterCodecs ?? [:] {
                    guard operation.parameters[name] != nil, action.parameters.first(where: { $0.name == name })?.family == codec,
                          AutomationCodecRegistry.parameterFamilies.contains(codec),
                          AutomationCodecRegistry.explicitParameterFamilies.contains(codec) || operation.parameters[name] == .null else { throw missing() }
                }
                for parameter in action.parameters {
                    guard let family = parameter.family,
                          AutomationCodecRegistry.explicitParameterFamilies.union(["text", "bool", "integer", "decimal", "date", "enum", "entity"]).contains(family) else { throw missing() }
                    if family == "enum" {
                        guard let type = parameter.typeID, catalog.enumerations?.filter({ $0.typeID == type }).count == 1 else { throw missing() }
                    }
                    if let binding = bindings.first(where: { $0.name == parameter.name }) {
                        guard operation.parameters[parameter.name] == nil,
                              try bindingMatches(binding, family: family, typeID: parameter.typeID, plan: plan, catalog: catalog) else { throw missing() }
                    } else if let value = operation.parameters[parameter.name] {
                        if AutomationCodecRegistry.explicitParameterFamilies.contains(family), value != .omission, value != .null {
                            guard operation.parameterCodecs?[parameter.name] == family else { throw missing() }
                        }
                        if family == "entity", case .entity(let type, _) = value {
                            guard type == parameter.typeID, catalog.entities?.filter({ $0.typeID == type }).count == 1 else { throw missing() }
                            try value.validate()
                        } else {
                            do { try AutomationCodecRegistry.validate(value, parameter: parameter, catalog: catalog) }
                            catch { throw missing() }
                        }
                    } else if !parameter.optional && parameter.defaultValue == nil { throw missing() }
                }
                if let codec = operation.resultCodec, codec != "noValue" {
                    guard codec == action.resultFamily else { throw missing() }
                }
                guard AutomationCodecRequirements.declared(operation, action: action, bindings: bindings)
                    .isSubset(of: Set(segment.requiredCapabilities)) else { throw missing() }
            }
        }
    }

    private static func validateQuery(_ operation: AutomationHostProgram.Operation, catalog: ApplicationSurfaceCatalog) throws {
        let entities = (catalog.entities ?? []).filter { $0.typeID == operation.typeID }
        guard entities.count == 1, let entity = entities.first,
              AutomationHostProgram.identifier(entity.queryIdentifier),
              (operation.properties ?? [:]).allSatisfy({ name, codec in
                  ["text", "bool", "integer"].contains(codec) && entity.properties[name] == codec
              }) else {
            throw AutomationContractError.missingEvidence("Prepared query does not match the selected app's entity and property declarations")
        }
    }

    private static func bindingMatches(_ binding: AutomationInputBinding, family: String, typeID: String?,
                                       plan: AutomationCase, catalog: ApplicationSurfaceCatalog) throws -> Bool {
        guard let producer = plan.setup.first(where: { $0.id == binding.producerSegmentID }) else { return false }
        if let selection = binding.uniqueEntity {
            guard family == "entity", selection.typeID == typeID,
                  catalog.entities?.filter({ $0.typeID == typeID }).count == 1,
                  let query = producer.hostProgram?.operations.first(where: { $0.id == binding.outputID }),
                  query.kind == .query, query.typeID == typeID else { return false }
            try selection.validate(query: query)
            return true
        }
        if let codec = binding.parameterCodec {
            guard codec == family, AutomationInputResolver.deferredParameterCodecs.contains(codec) else { return false }
            return producer.hostProgram?.operations.contains(where: {
                $0.id == binding.outputID && $0.kind == .invoke && $0.resultCodec == family
            }) == true
        }
        // Unannotated bindings retain their scalar-only contract.
        guard ["text", "bool", "integer", "decimal", "date"].contains(family) else { return false }
        if let output = producer.uiProgram?.operations.first(where: { $0.id == binding.outputID && $0.kind == .observeProperty }) {
            return (["text", "value"].contains(output.property) && family == "text")
                || (["checked", "selected"].contains(output.property) && family == "bool")
        }
        return producer.hostProgram?.operations.contains(where: {
            $0.id == binding.outputID && $0.kind == .invoke && $0.resultCodec == family
        }) == true
    }

    private static func missing() -> AutomationContractError {
        .missingEvidence("Prepared program does not match the selected app's input and result declarations")
    }
}
