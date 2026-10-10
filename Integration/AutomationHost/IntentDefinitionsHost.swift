import AppIntentsTesting
import AppIntents
import Foundation
import UniformTypeIdentifiers

@MainActor
enum IntentDefinitionsHost {
    static func assign(_ input: HostInput, name: String, codec: String?, intent: inout AnyAppIntent, definitions: IntentDefinitions) throws {
        switch input.kind {
        case "omission": return
        case "null": intent[dynamicMember: name] = nil
        case "text": intent[dynamicMember: name] = try required(input.value)
        case "bool": intent[dynamicMember: name] = try required(input.boolValue)
        case "integer":
            guard let value = Int64(try required(input.value)) else { throw HostError.unsupportedCodec("integer") }
            intent[dynamicMember: name] = value
        case "decimal":
            guard let value = Double(try required(input.value)), value.isFinite else { throw HostError.unsupportedCodec("decimal") }
            intent[dynamicMember: name] = value
        case "date": intent[dynamicMember: name] = try HostDateCodec.decode(input)
        case "object":
            switch codec {
            case "duration": intent[dynamicMember: name] = try HostDurationCodec.decode(input)
            case "calendarComponents": intent[dynamicMember: name] = try HostCalendarCodec.decode(input)
            case "url": intent[dynamicMember: name] = try HostURLCodec.decode(input)
            default: throw HostError.unsupportedCodec("Structured input")
            }
        case "intentFile":
            guard codec == "intentFile" else { throw HostError.unsupportedCodec("File input") }
            let (data, metadata) = try HostIntentFileCodec.decode(input)
            intent[dynamicMember: name] = IntentFile(data: data, filename: metadata.filename, type: metadata.typeIdentifier.flatMap { UTType($0) })
        case "array":
            switch codec ?? "textArray" {
            case "textArray": intent[dynamicMember: name] = try HostArrayCodec.texts(input)
            case "boolArray": intent[dynamicMember: name] = try HostArrayCodec.bools(input)
            case "integerArray": intent[dynamicMember: name] = try HostArrayCodec.integers(input)
            case "decimalArray": intent[dynamicMember: name] = try HostArrayCodec.decimals(input)
            case "dateArray": intent[dynamicMember: name] = try HostArrayCodec.dates(input)
            default: throw HostError.unsupportedCodec("array")
            }
        case "entity": intent[dynamicMember: name] = definitions.entities[try required(input.typeId)].makeReference(identifier: try required(input.value))
        case "enum": intent[dynamicMember: name] = definitions.enums[try required(input.typeId)].makeCase(try required(input.value))
        default: throw HostError.unsupportedCodec(input.kind)
        }
    }
    static func execute(_ operation: HostOperation, bundleID: String) async throws -> HostValue {
        let definitions = IntentDefinitions(bundleIdentifier: bundleID)
        switch operation.kind {
        case .invoke:
            let definition = definitions.intents[operation.typeID]
            var intent = definition.makeIntent()
            try HostIntentIdentity.validate(bundle: bundleID, action: operation.typeID, definitionsBundle: definitions.bundleIdentifier,
                definitionBundle: definition.bundleIdentifier, definitionID: definition.identifier, intentBundle: intent.bundleIdentifier, intentID: intent.identifier)
            for (name, input) in operation.parameters {
                try assign(input, name: name, codec: operation.parameterCodecs?[name], intent: &intent, definitions: definitions)
            }
            let result = try await intent.run()
            switch operation.resultCodec {
            case nil, "noValue": return HostValue(kind: "noValue")
            case "text": let value: String = try result.value; return HostValue(kind: "text", value: value)
            case "bool": let value: Bool = try result.value; return HostValue(kind: "bool", boolValue: value)
            case "integer": let value: Int = try result.value; return HostValue(kind: "integer", value: String(value))
            case "decimal":
                let value: Double = try result.value
                guard value.isFinite else { throw HostError.unsupportedCodec("nonfinite decimal") }
                return HostValue(kind: "decimal", value: try HostDecimalCodec.encode(value))
            case "date": let value: Date = try result.value
                return try HostDateCodec.encode(value)
            case "intentFile": let value: IntentFile = try result.value
                return try HostIntentFileCodec.encode(data: value.data, filename: value.filename, typeIdentifier: value.type?.identifier, operationID: operation.id)
            case "url": let value: URL = try result.value
                return try HostURLCodec.encode(value)
            case "calendarComponents": let value: DateComponents = try result.value
                return try HostCalendarCodec.encode(value)
            case "duration": let value: Duration = try result.value
                return try HostDurationCodec.encode(value)
            case "textArray": let values: [String] = try result.value
                guard values.count <= 1000 else { throw HostError.unsupportedCodec("Collection limit") }; return HostValue(kind: "array", items: values.map { HostValue(kind: "text", value: $0) })
            case "boolArray": let values: [Bool] = try result.value
                guard values.count <= 1000 else { throw HostError.unsupportedCodec("Collection limit") }; return HostValue(kind: "array", items: values.map { HostValue(kind: "bool", boolValue: $0) })
            case "integerArray": let values: [Int] = try result.value
                return try HostArrayCodec.encodeIntegers(values)
            case "decimalArray": let values: [Double] = try result.value
                guard values.count <= 1000 else { throw HostError.unsupportedCodec("Collection limit") }; return HostValue(kind: "array", items: try values.map { HostValue(kind: "decimal", value: try HostDecimalCodec.encode($0)) })
            case "dateArray": let values: [Date] = try result.value
                guard values.count <= 1000 else { throw HostError.unsupportedCodec("Collection limit") }
                return HostValue(kind: "array", items: try values.map(HostDateCodec.encode))
            default: throw HostError.unsupportedCodec(operation.resultCodec ?? "unknown")
            }
        case .query:
            let definition = definitions.entities[operation.typeID]
            let entities: [AnyAppEntity]
            if let ids = operation.queryIDs { entities = try await definition.entities(identifiers: ids) }
            else if let text = operation.queryText { entities = try await definition.entities(matching: text) }
            else { throw HostError.unsupportedCodec("Query requires explicit IDs or matching text") }
            guard entities.count <= 1000 else { throw HostError.unsupportedCodec("Collection limit") }
            var output: [HostValue] = []
            for entity in entities {
                var properties: [String: HostValue] = [:]
                for (name, codec) in operation.properties ?? [:] {
                    switch codec {
                    case "text": let value: String = try entity[dynamicMember: name]; properties[name] = HostValue(kind: "text", value: value)
                    case "bool": let value: Bool = try entity[dynamicMember: name]; properties[name] = HostValue(kind: "bool", boolValue: value)
                    case "integer": let value: Int = try entity[dynamicMember: name]; properties[name] = HostValue(kind: "integer", value: String(value))
                    default: throw HostError.unsupportedCodec(codec)
                    }
                }
                output.append(HostValue(kind: "entity", value: entity.identifier.instanceIdentifier, typeId: entity.identifier.entityType.persistentIdentifier, properties: properties))
            }
            return HostValue(kind: "array", items: output)
        }
    }
    private static func required<T>(_ value: T?) throws -> T {
        guard let value else { throw HostError.invalidPlan }; return value
    }
}
enum HostError: Error { case invalidPlan, unsupportedCodec(String) }
