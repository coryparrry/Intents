import Foundation
import IntentsAutomationDateCodec

/// Validate URL use against the selected product's retained declaration, even
/// when a frozen program omits its own codec annotation. No resolver guessing.
enum AutomationURLProgramContract {
    static func validate(_ plan: AutomationCase, catalog: ApplicationSurfaceCatalog) throws {
        guard catalog.app == plan.app else { throw AutomationContractError.conflictingOperation }
        for segment in plan.setup + [plan.execution] + plan.observations + plan.cleanup {
            for operation in segment.hostProgram?.operations ?? [] where operation.kind == .invoke {
                let usesURL = operation.resultCodec == "url" || operation.parameterCodecs?.values.contains("url") == true
                let candidates = catalog.systemActions.filter { $0.id == operation.typeID && $0.compiled }
                guard candidates.count == 1, let action = candidates.first else {
                    if usesURL { throw missing() }; continue
                }
                for (name, codec) in operation.parameterCodecs ?? [:] where codec == "url" {
                    guard action.parameters.filter({ $0.name == name && $0.family == "url" }).count == 1 else { throw missing() }
                }
                for parameter in action.parameters where parameter.family == "url" {
                    guard segment.inputBindings?.contains(where: {
                        $0.destination == .hostParameter && $0.operationID == operation.id && $0.name == parameter.name
                    }) != true else { throw missing() }
                    guard let value = operation.parameters[parameter.name] else {
                        if !parameter.optional && parameter.defaultValue == nil { throw missing() }; continue
                    }
                    if value == .omission {
                        guard parameter.optional || parameter.defaultValue != nil else { throw missing() }; continue
                    }
                    if value == .null { guard parameter.optional else { throw missing() }; continue }
                    guard operation.parameterCodecs?[parameter.name] == "url",
                          segment.requiredCapabilities.contains("apple.codec.url") else { throw missing() }
                    _ = try AutomationURLReference(taggedValue: value)
                }
                if operation.resultCodec == "url" {
                    guard action.resultFamily == "url", segment.requiredCapabilities.contains("apple.codec.url") else { throw missing() }
                } else if action.resultFamily == "url", let codec = operation.resultCodec, codec != "noValue" { throw missing() }
            }
        }
    }
    private static func missing() -> AutomationContractError {
        .missingEvidence("URL program does not match its selected declaration and qualified codec")
    }
}
