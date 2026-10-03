import AppIntentsTesting
import Foundation
import IntentLabContracts

@available(macOS 27.0, iOS 27.0, *)
@MainActor
public enum IntentProbe {
    public static func run(_ scenario: IntentLabScenario) async throws -> [String: IntentLabValue] {
        let result = try await invoke(
            bundleIdentifier: scenario.target.bundleIdentifier,
            intentIdentifier: scenario.directControl.intentIdentifier,
            parameters: scenario.directControl.parameters
        )

        var observations: [String: IntentLabValue] = [:]
        for field in scenario.directControl.outputFields {
            guard observations[field.name] == nil else { throw IntentProbeError.invalidValue(field.name) }
            observations[field.name] = try project(field, from: result, schemaVersion: scenario.schemaVersion ?? 1)
        }
        if scenario.schemaVersion == 1, scenario.directControl.outputFields.count == 1,
           let field = scenario.directControl.outputFields.first,
           case .string(let text) = observations[field.name] {
            observations["visibleResponse"] = .string(text)
        }
        return observations
    }

    static func invokeTestIntent(
        bundleIdentifier: String,
        intentIdentifier: String,
        parameters: [IntentLabParameter],
        outputProjections: [IntentLabIntegrationDeclaration.Projection]
    ) async throws -> [String: IntentLabValue] {
        let result = try await invoke(
            bundleIdentifier: bundleIdentifier,
            intentIdentifier: intentIdentifier,
            parameters: parameters
        )

        var observations: [String: IntentLabValue] = [:]
        for projection in outputProjections {
            let field = IntentLabOutputField(
                name: projection.id,
                type: projection.type,
                path: projection.path
            )
            guard observations[field.name] == nil else {
                throw IntentProbeError.invalidValue(field.name)
            }
            observations[field.name] = try project(field, from: result, schemaVersion: 2)
        }
        return observations
    }

    private static func invoke(
        bundleIdentifier: String,
        intentIdentifier: String,
        parameters: [IntentLabParameter]
    ) async throws -> ResolvedIntentResult {
        let definitions = IntentDefinitions(bundleIdentifier: bundleIdentifier)
        let definition = definitions.intents[intentIdentifier]
        var intent = definition.makeIntent()
        for parameter in parameters {
            try set(parameter, on: &intent, definitions: definitions)
        }
        return try await intent.run()
    }

    private static func project(
        _ field: IntentLabOutputField,
        from result: ResolvedIntentResult,
        schemaVersion: Int
    ) throws -> IntentLabValue {
        let components = field.path ?? []
        if schemaVersion == 2 && (components.first?.kind != .property || components.first?.name != "value") {
            throw IntentProbeError.unsupportedOutput("Output \(field.name) needs an explicit projection path.")
        }
        var path: DynamicPropertyPath = result.value
        let tail = Array(components.dropFirst(schemaVersion == 2 ? 1 : 0))
        for (position, component) in tail.enumerated() {
            switch component.kind {
            case .property:
                guard let name = component.name, !name.isEmpty else { throw IntentProbeError.invalidValue(field.name) }
                path = path[dynamicMember: name]
            case .index:
                guard let index = component.index, index >= 0 else { throw IntentProbeError.invalidValue(field.name) }
                path = path[index]
            case .count:
                guard position == tail.count - 1, case .primitive(.integer) = field.type else {
                    throw IntentProbeError.unsupportedOutput("Count projections must end an integer output path.")
                }
                let count: Int = try path[dynamicMember: "count"]
                return .integer(Int64(count))
            }
        }
        switch field.type {
        case .primitive(.string):
            let value: String = try path.as(String.self)
            return .string(value)
        case .primitive(.boolean):
            let value: Bool = try path.as(Bool.self)
            return .boolean(value)
        case .primitive(.integer):
            let value: Int = try path.as(Int.self)
            return .integer(Int64(value))
        case .primitive(.number):
            let value: Double = try path.as(Double.self)
            guard value.isFinite else { throw IntentProbeError.invalidValue(field.name) }
            return .number(value)
        case .primitive(.date):
            let value: Date = try path.as(Date.self)
            return .date(.init(source: ISO8601DateFormatter().string(from: value), timeZoneIdentifier: "UTC", resolvedInstant: value))
        case .enumeration(let identifier, let allowedCases):
            let value: AnyAppEnum = try path.as(AnyAppEnum.self)
            guard value.typeIdentifier == identifier, allowedCases.contains(value.rawValue) else {
                throw IntentProbeError.invalidValue(field.name)
            }
            return .enumeration(.init(typeIdentifier: identifier, caseIdentifier: value.rawValue))
        case .entity(let identifier):
            let value: AnyAppEntity = try path.as(AnyAppEntity.self)
            guard value.identifier.entityType.persistentIdentifier == identifier else {
                throw IntentProbeError.invalidValue(field.name)
            }
            return .entity(.init(typeIdentifier: identifier, identifier: value.identifier.instanceIdentifier))
        case .array(let element):
            return .array(try projectArray(element: element, path: path, name: field.name))
        }
    }

    private static func projectArray(
        element: IntentLabValueType,
        path: DynamicPropertyPath,
        name: String
    ) throws -> [IntentLabValue] {
        switch element {
        case .primitive(.string):
            let values: [String] = try path.as([String].self)
            return values.map(IntentLabValue.string)
        case .primitive(.boolean):
            let values: [Bool] = try path.as([Bool].self)
            return values.map(IntentLabValue.boolean)
        case .primitive(.integer):
            let values: [Int] = try path.as([Int].self)
            return values.map { .integer(Int64($0)) }
        case .primitive(.number):
            let values: [Double] = try path.as([Double].self)
            guard values.allSatisfy(\.isFinite) else { throw IntentProbeError.invalidValue(name) }
            return values.map(IntentLabValue.number)
        case .primitive(.date):
            let values: [Date] = try path.as([Date].self)
            return values.map { value in
                .date(.init(source: ISO8601DateFormatter().string(from: value), timeZoneIdentifier: "UTC", resolvedInstant: value))
            }
        case .enumeration(let identifier, let allowedCases):
            let values: [AnyAppEnum] = try path.as([AnyAppEnum].self)
            guard values.allSatisfy({ $0.typeIdentifier == identifier && allowedCases.contains($0.rawValue) }) else {
                throw IntentProbeError.invalidValue(name)
            }
            return values.map { .enumeration(.init(typeIdentifier: identifier, caseIdentifier: $0.rawValue)) }
        case .entity(let identifier):
            let values: [AnyAppEntity] = try path.as([AnyAppEntity].self)
            guard values.allSatisfy({ $0.identifier.entityType.persistentIdentifier == identifier }) else {
                throw IntentProbeError.invalidValue(name)
            }
            return values.map { .entity(.init(typeIdentifier: identifier, identifier: $0.identifier.instanceIdentifier)) }
        case .array:
            throw IntentProbeError.unsupportedOutput("Nested arrays are not supported for output \(name).")
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
        case .primitive(.string):
            let mapped: [String] = try values.map { guard case .string(let value) = $0 else { throw IntentProbeError.invalidValue(name) }; return value }
            intent[dynamicMember: name] = mapped
        case .primitive(.boolean):
            let mapped: [Bool] = try values.map { guard case .boolean(let value) = $0 else { throw IntentProbeError.invalidValue(name) }; return value }
            intent[dynamicMember: name] = mapped
        case .primitive(.integer):
            let mapped: [Int64] = try values.map { guard case .integer(let value) = $0 else { throw IntentProbeError.invalidValue(name) }; return value }
            intent[dynamicMember: name] = mapped
        case .primitive(.number):
            let mapped: [Double] = try values.map { guard case .number(let value) = $0, value.isFinite else { throw IntentProbeError.invalidValue(name) }; return value }
            intent[dynamicMember: name] = mapped
        case .primitive(.date):
            let mapped: [Date] = try values.map { guard case .date(let value) = $0 else { throw IntentProbeError.invalidValue(name) }; return value.resolvedInstant }
            intent[dynamicMember: name] = mapped
        case .enumeration(let identifier, _):
            let mapped: [AnyAppEnum] = try values.map { guard case .enumeration(let value) = $0, value.typeIdentifier == identifier else { throw IntentProbeError.invalidValue(name) }; return definitions.enums[identifier].makeCase(value.caseIdentifier) }
            intent[dynamicMember: name] = mapped
        case .entity(let identifier):
            let mapped: [AnyAppEntity] = try values.map { guard case .entity(let value) = $0, value.typeIdentifier == identifier else { throw IntentProbeError.invalidValue(name) }; return definitions.entities[identifier].makeReference(identifier: value.identifier) }
            intent[dynamicMember: name] = mapped
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
