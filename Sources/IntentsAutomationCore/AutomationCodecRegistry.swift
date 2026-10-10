import Foundation
import IntentsAutomationDateCodec

extension ApplicationSurfaceCatalog {
    public struct Enumeration: Codable, Equatable, Sendable, Identifiable {
        public struct Case: Codable, Equatable, Sendable, Identifiable {
            public var id: String
            public var title: String
        }
        public var typeID: String
        public var title: String
        public var cases: [Case]
        public var id: String { typeID }
    }
}

/// Closed input codecs. Declaration discovery never establishes successful runtime conversion.
public enum AutomationCodecRegistry {
    public static let arrayFamilies: Set<String> = ["textArray", "boolArray", "integerArray", "decimalArray", "dateArray"]
    static let explicitParameterFamilies = arrayFamilies.union(["duration", "calendarComponents", "url", "intentFile"])
    static let parameterFamilies = explicitParameterFamilies.union(["text", "bool", "integer", "decimal", "date", "enum", "entity"])
    static func matchesArray(_ items: [AutomationValue], family: String) -> Bool {
        guard arrayFamilies.contains(family), items.count <= 1000 else { return false }
        return items.allSatisfy { value in
            switch (family, value) {
            case ("textArray", .text), ("boolArray", .bool): return true
            case ("integerArray", .integer(let text)): return Int64(text) != nil
            case ("decimalArray", .decimal(let text)): return Double(text)?.isFinite == true
            case ("dateArray", .date(let text, let zone)): return (try? AutomationDateCodec.decode(value: text, timeZone: zone)) != nil
            default: return false
            }
        }
    }
    public static func validate(_ value: AutomationValue, parameter: ApplicationSurfaceCatalog.SystemAction.Parameter,
                                catalog: ApplicationSurfaceCatalog) throws {
        try value.validate()
        let matches: Bool
        switch (parameter.family, value) {
        case ("text", .text), ("bool", .bool): matches = true
        case ("integer", .integer(let number)): matches = Int64(number) != nil
        case ("decimal", .decimal(let number)): matches = Double(number)?.isFinite == true
        case ("date", .date(let timestamp, let zone)): matches = (try? AutomationDateCodec.decode(value: timestamp, timeZone: zone)) != nil
        case ("calendarComponents", .object): matches = (try? AutomationCalendarInput(taggedValue: value)) != nil
        case ("duration", .object): matches = (try? AutomationDurationInput(taggedValue: value)) != nil
        case ("intentFile", .artifact): matches = true
        case ("url", .object): matches = (try? AutomationURLReference(taggedValue: value)) != nil
        case ("enum", .enumeration(let type, let identifier)):
            matches = parameter.typeID == type && catalog.enumerations?.first(where: { $0.typeID == type })?.cases.contains(where: { $0.id == identifier }) == true
        case (let family?, .array(let items)): matches = matchesArray(items, family: family)
        case (_, .null): matches = parameter.optional && parameter.family != nil && parameter.family != "entity"
        case (_, .omission): matches = parameter.optional || parameter.defaultValue != nil
        default: matches = false
        }
        guard matches else { throw AutomationContractError.invalidPlan("Input has no matching declared codec: " + parameter.name) }
    }
    public static func input(_ text: String, parameter: ApplicationSurfaceCatalog.SystemAction.Parameter,
                             catalog: ApplicationSurfaceCatalog) throws -> AutomationActionInput {
        let value: AutomationValue
        switch parameter.family {
        case "text": value = .text(text)
        case "bool":
            guard ["true", "false"].contains(text) else { throw AutomationContractError.invalidPlan("Choose true or false") }
            value = .bool(text == "true")
        case "integer": value = .integer(text)
        case "decimal": value = .decimal(text)
        case "date": value = try AutomationDateInput.parse(text).taggedValue
        case "url": value = try AutomationURLReference(text).taggedValue
        case "calendarComponents":
            guard text.utf8.count <= 4096 else { throw AutomationContractError.invalidPlan("Calendar input exceeds its limit") }
            value = try AutomationCalendarInput.parse(Data(text.utf8)).taggedValue
        case "duration":
            guard text.utf8.count <= 1024 else { throw AutomationContractError.invalidPlan("Duration input exceeds its limit") }
            value = try AutomationDurationInput.parse(Data(text.utf8)).taggedValue
        case "enum": value = .enumeration(typeID: parameter.typeID ?? "", value: text)
        case let family? where arrayFamilies.contains(family):
            guard text.utf8.count <= 65536, let data = text.data(using: .utf8) else { throw AutomationContractError.invalidPlan("Array input exceeds its limit") }
            let decoder = JSONDecoder()
            switch family {
            case "textArray": value = .array(try decoder.decode([String].self, from: data).map(AutomationValue.text))
            case "boolArray": value = .array(try decoder.decode([Bool].self, from: data).map(AutomationValue.bool))
            case "integerArray": value = .array(try decoder.decode([Int64].self, from: data).map { .integer(String($0)) })
            case "decimalArray": value = .array(try decoder.decode([String].self, from: data).map(AutomationValue.decimal))
            case "dateArray":
                let dates = try decoder.decode([[String: String]].self, from: data)
                value = .array(try dates.map { try AutomationDateInput.parse(String(decoding: JSONSerialization.data(withJSONObject: $0), as: UTF8.self)).taggedValue })
            default: throw AutomationContractError.invalidPlan("Unsupported collection")
            }
        default: throw AutomationContractError.invalidPlan("Unsupported input declaration")
        }
        try validate(value, parameter: parameter, catalog: catalog)
        return .init(value: value, origin: .userChoice, evidence: "Typed input entered in the native approval")
    }
    public static func declaredDefault(_ parameter: ApplicationSurfaceCatalog.SystemAction.Parameter,
                                       catalog: ApplicationSurfaceCatalog) throws -> AutomationActionInput? {
        guard let value = parameter.defaultValue else { return nil }
        try validate(value, parameter: parameter, catalog: catalog)
        return .init(value: value, origin: .declaredDefault, evidence: "Default in the exact built SDK metadata")
    }
}
