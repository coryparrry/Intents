import Foundation
import CoreFoundation

/// Descriptor shapes captured in Fixtures/CodecMetadata for Xcode 27A266a, version 1.
enum AutomationCodecMetadata {
    static func primitiveFamily(_ identifier: Int?) -> String? {
        switch identifier { case 0: "text"; case 1: "bool"; case 2: "integer"; case 7: "decimal"; case 8: "date"; case 9: "calendarComponents"; case 11: "url"; default: nil }
    }
    static func inputPrimitiveFamily(_ identifier: Int?) -> String? { identifier == 8 ? "date" : primitiveFamily(identifier) }
    static func intentFile(_ value: [String: Any]?) -> Bool {
        guard let value, Set(value.keys) == ["intents"], let intents = value["intents"] as? [String: Any],
              Set(intents.keys) == ["wrapper"], let wrapper = intents["wrapper"] as? [String: Any],
              Set(wrapper.keys) == ["typeIdentifier"], let number = wrapper["typeIdentifier"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue == 12
    }
    static func enumerationType(_ value: [String: Any]?) -> String? {
        guard let value, Set(value.keys) == ["linkEnumeration"], let linked = value["linkEnumeration"] as? [String: Any],
              Set(linked.keys) == ["wrapper"], let wrapper = linked["wrapper"] as? [String: Any], Set(wrapper.keys) == ["identifier"],
              let id = wrapper["identifier"] as? String, AutomationHostProgram.identifier(id) else { return nil }
        return id
    }
    static func arrayFamily(_ value: [String: Any]?, input: Bool = true) -> String? {
        guard let value, Set(value.keys) == ["array"], let array = value["array"] as? [String: Any], Set(array.keys) == ["wrapper"],
              let wrapper = array["wrapper"] as? [String: Any], Set(wrapper.keys) == ["capabilities", "memberValueType"],
              let capabilities = wrapper["capabilities"] as? NSNumber, CFGetTypeID(capabilities) != CFBooleanGetTypeID(),
              capabilities.doubleValue == 3 else { return nil }
        let primitive = AutomationEntityMetadata.primitive(wrapper["memberValueType"] as? [String: Any])
        guard let family = input ? inputPrimitiveFamily(primitive) : primitiveFamily(primitive), ["text", "bool", "integer", "decimal", "date"].contains(family) else { return nil }
        return family + "Array"
    }
    static func duration(_ value: [String: Any]?) -> Bool {
        guard let value, Set(value.keys) == ["entity"], let entity = value["entity"] as? [String: Any], Set(entity.keys) == ["wrapper"],
              let wrapper = entity["wrapper"] as? [String: Any], Set(wrapper.keys) == ["codable", "typeName"], wrapper["typeName"] as? String == "Swift.Duration",
              let codable = wrapper["codable"] as? [String: Any], Set(codable.keys) == ["availabilityAnnotations", "contentTypeIdentifier", "mangledTypeName"],
              codable["contentTypeIdentifier"] as? String == "com.apple.Foundation.Duration", codable["mangledTypeName"] as? String == "s8DurationV",
              let availability = codable["availabilityAnnotations"] as? [String: [String: String]],
              Set(availability.keys) == ["LNPlatformNameIOS", "LNPlatformNameMACOS", "LNPlatformNameTVOS", "LNPlatformNameVISIONOS", "LNPlatformNameWATCHOS"],
              availability.values.allSatisfy({ $0 == ["introducedVersion": "26.0"] }) else { return false }
        return true
    }
    static func enumerations(_ root: [String: Any]) -> [ApplicationSurfaceCatalog.Enumeration] {
        guard let declarations = root["enums"] as? [[String: Any]], declarations.count <= 1000 else { return [] }
        let grouped = Dictionary(grouping: declarations, by: { $0["identifier"] as? String ?? "" })
        return grouped.sorted(by: { $0.key < $1.key }).compactMap { id, group in
            guard group.count == 1, AutomationHostProgram.identifier(id), let entry = group.first,
                  entry["isSystem"] as? Bool == false, let cases = entry["cases"] as? [[String: Any]], (1...1000).contains(cases.count) else { return nil }
            var values: [ApplicationSurfaceCatalog.Enumeration.Case] = []
            for item in cases {
                guard let name = item["identifier"] as? String, AutomationHostProgram.identifier(name), !values.contains(where: { $0.id == name }) else { return nil }
                let title = ((item["displayRepresentation"] as? [String: Any])?["title"] as? [String: Any])?["key"] as? String ?? name
                values.append(.init(id: name, title: title))
            }
            return .init(typeID: id, title: (entry["displayTypeName"] as? [String: Any])?["key"] as? String ?? id, cases: values)
        }
    }
    static func defaultValue(_ metadata: [String: Any], declaration: ApplicationSurfaceCatalog.SystemAction.Parameter,
                             enumerations: [ApplicationSurfaceCatalog.Enumeration]) -> AutomationValue? {
        guard let pairs = metadata["typeSpecificMetadata"] as? [Any], pairs.count <= 100, pairs.count.isMultiple(of: 2) else { return nil }
        var found: [String: Any]?
        for index in stride(from: 0, to: pairs.count, by: 2) {
            guard let key = pairs[index] as? String else { return nil }
            if key == "LNValueTypeSpecificMetadataKeyDefaultValue" {
                guard found == nil, let value = pairs[index + 1] as? [String: Any], value.count == 1 else { return nil }
                found = value
            }
        }
        guard let found else { return nil }
        func wrapper(_ key: String) -> Any? {
            guard Set(found.keys) == [key], let wrapped = found[key] as? [String: Any], Set(wrapped.keys) == ["wrapper"] else { return nil }
            return wrapped["wrapper"]
        }
        switch declaration.family {
        case "text": if let value = wrapper("string") as? String { return .text(value) }
        case "enum":
            if let value = wrapper("string") as? String, let type = declaration.typeID,
               enumerations.first(where: { $0.typeID == type })?.cases.contains(where: { $0.id == value }) == true { return .enumeration(typeID: type, value: value) }
        case "bool", "integer":
            if let number = wrapper("int") as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
               let integer = Int64(number.stringValue), number.doubleValue == Double(integer) {
                if declaration.family == "integer" { return .integer(String(integer)) }
                if [0, 1].contains(integer) { return .bool(integer == 1) }
            }
        case "decimal":
            if let number = wrapper("double") as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
                let value = AutomationValue.decimal(number.stringValue)
                if (try? value.validate()) != nil { return value }
            }
        default: break
        }
        return nil
    }
}
