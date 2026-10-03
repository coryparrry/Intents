import AppIntentsTesting
import Foundation

@available(iOS 27.0, *)
@MainActor
enum IntentProbe {
    static func run(_ scenario: IntentLabScenario) async throws -> [String: IntentLabValue] {
        let definitions = IntentDefinitions(bundleIdentifier: scenario.target.bundleIdentifier)
        let definition = definitions.intents[scenario.directControl.intentIdentifier]
        var intent = definition.makeIntent()
        for parameter in scenario.directControl.parameters {
            try set(parameter, on: &intent, definitions: definitions)
        }
        let result = try await intent.run()

        // AppIntentsTesting intentionally exposes result members through typed dynamic
        // lookup. The generic template supports one String result value; integrations
        // should extend this allowlist deliberately instead of reflecting private data.
        guard scenario.directControl.outputFields.count <= 1 else {
            throw IntentProbeError.unsupportedOutput("Declare a project-specific extractor for multiple result fields.")
        }
        guard let field = scenario.directControl.outputFields.first else { return [:] }
        switch field.type {
        case .primitive(.string):
            let value: String = try result.value
            return [field.name: .string(value), "visibleResponse": .string(value)]
        default:
            throw IntentProbeError.unsupportedOutput("The generic extractor currently supports a String result value.")
        }
    }

    private static func set(
        _ parameter: IntentLabParameter,
        on intent: inout AnyAppIntent,
        definitions: IntentDefinitions
    ) throws {
        switch parameter.presence {
        case .missing:
            return
        case .value(.null):
            intent[dynamicMember: parameter.name] = nil
        case .value(.string(let value)):
            intent[dynamicMember: parameter.name] = value
        case .value(.boolean(let value)):
            intent[dynamicMember: parameter.name] = value
        case .value(.integer(let value)):
            intent[dynamicMember: parameter.name] = value
        case .value(.number(let value)):
            guard value.isFinite else { throw IntentProbeError.invalidValue(parameter.name) }
            intent[dynamicMember: parameter.name] = value
        case .value(.date(let value)):
            guard TimeZone(identifier: value.timeZoneIdentifier) != nil else { throw IntentProbeError.invalidValue(parameter.name) }
            intent[dynamicMember: parameter.name] = value.resolvedInstant
        case .value(.enumeration(let value)):
            intent[dynamicMember: parameter.name] = definitions.enums[value.typeIdentifier].makeCase(value.caseIdentifier)
        case .value(.entity(let value)):
            intent[dynamicMember: parameter.name] = definitions.entities[value.typeIdentifier].makeReference(identifier: value.identifier)
        case .value(.array(let values)):
            try setArray(values, type: parameter.type, name: parameter.name, on: &intent, definitions: definitions)
        }
    }

    private static func setArray(
        _ values: [IntentLabValue],
        type: IntentLabValueType,
        name: String,
        on intent: inout AnyAppIntent,
        definitions: IntentDefinitions
    ) throws {
        guard case .array(let element) = type else { throw IntentProbeError.invalidValue(name) }
        switch element {
        case .primitive(.string): intent[dynamicMember: name] = try values.map { guard case .string(let value) = $0 else { throw IntentProbeError.invalidValue(name) }; return value }
        case .primitive(.boolean): intent[dynamicMember: name] = try values.map { guard case .boolean(let value) = $0 else { throw IntentProbeError.invalidValue(name) }; return value }
        case .primitive(.integer): intent[dynamicMember: name] = try values.map { guard case .integer(let value) = $0 else { throw IntentProbeError.invalidValue(name) }; return value }
        case .primitive(.number): intent[dynamicMember: name] = try values.map { guard case .number(let value) = $0, value.isFinite else { throw IntentProbeError.invalidValue(name) }; return value }
        case .primitive(.date): intent[dynamicMember: name] = try values.map { guard case .date(let value) = $0 else { throw IntentProbeError.invalidValue(name) }; return value.resolvedInstant }
        case .enumeration(let identifier, _): intent[dynamicMember: name] = try values.map { guard case .enumeration(let value) = $0, value.typeIdentifier == identifier else { throw IntentProbeError.invalidValue(name) }; return definitions.enums[identifier].makeCase(value.caseIdentifier) }
        case .entity(let identifier): intent[dynamicMember: name] = try values.map { guard case .entity(let value) = $0, value.typeIdentifier == identifier else { throw IntentProbeError.invalidValue(name) }; return definitions.entities[identifier].makeReference(identifier: value.identifier) }
        case .array: throw IntentProbeError.invalidValue(name)
        }
    }
}

enum IntentProbeError: LocalizedError {
    case invalidValue(String)
    case unsupportedOutput(String)

    var errorDescription: String? {
        switch self {
        case .invalidValue(let name): "The value for \(name) does not match its declared type."
        case .unsupportedOutput(let detail): detail
        }
    }
}
