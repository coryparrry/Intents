import Foundation
import CoreFoundation

extension ApplicationSurfaceCatalog {
    public struct Entity: Codable, Equatable, Sendable, Identifiable {
        public var typeID: String
        public var title: String
        public var queryIdentifier: String
        public var properties: [String: String]
        public var propertyTitles: [String: String]
        public var id: String { typeID }
    }
}

/// Exact descriptor shapes captured from the retained Xcode 27A266a C2 product.
/// Declaration discovery is separate from successful runtime query evidence.
enum AutomationEntityMetadata {
    static func primitive(_ value: [String: Any]?) -> Int? {
        guard let value, Set(value.keys) == ["primitive"], let primitive = value["primitive"] as? [String: Any],
              Set(primitive.keys) == ["wrapper"], let wrapper = primitive["wrapper"] as? [String: Any],
              Set(wrapper.keys) == ["typeIdentifier"], let number = wrapper["typeIdentifier"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let integer = number.intValue
        guard number.doubleValue == Double(integer) else { return nil }
        return integer
    }
    static func entityType(_ value: [String: Any]?) -> String? {
        guard let value, Set(value.keys) == ["entity"], let entity = value["entity"] as? [String: Any],
              Set(entity.keys) == ["wrapper"], let wrapper = entity["wrapper"] as? [String: Any],
              Set(wrapper.keys) == ["typeName"], let name = wrapper["typeName"] as? String,
              AutomationHostProgram.identifier(name) else { return nil }
        return name
    }
    static func read(_ root: [String: Any]) -> [ApplicationSurfaceCatalog.Entity] {
        guard let entities = root["entities"] as? [String: [String: Any]], entities.count <= 1000,
              let queries = root["queries"] as? [String: [String: Any]], queries.count <= 1000 else { return [] }
        return entities.sorted(by: { $0.key < $1.key }).compactMap { typeID, entity in
            guard AutomationHostProgram.identifier(typeID), entity["typeName"] as? String == typeID,
                  entity["transient"] as? Bool == false,
                  let queryID = entity["defaultQueryIdentifier"] as? String,
                  let matching = queries.filter({ $0.value["fullyQualifiedIdentifier"] as? String == queryID }).only,
                  matching.value["identifier"] as? String == matching.key,
                  matching.value["entityType"] as? String == typeID,
                  matching.value["defaultQueryForEntity"] as? Bool == true,
                  matching.value["capabilities"] as? Int == 70,
                  entityType(matching.value["resultValueType"] as? [String: Any]) == typeID,
                  let properties = entity["properties"] as? [[String: Any]], (1...50).contains(properties.count) else { return nil }
            var codecs: [String: String] = [:], titles: [String: String] = [:]
            for property in properties {
                guard let name = property["identifier"] as? String, AutomationHostProgram.identifier(name), codecs[name] == nil,
                      property["isOptional"] as? Bool == false,
                      let primitive = primitive(property["valueType"] as? [String: Any]),
                      let codec = [0: "text", 1: "bool", 2: "integer"][primitive] else { return nil }
                codecs[name] = codec
                titles[name] = (property["title"] as? [String: Any])?["key"] as? String ?? name
            }
            guard codecs.values.contains("text") else { return nil }
            return .init(typeID: typeID, title: (entity["displayTypeName"] as? [String: Any])?["key"] as? String ?? typeID,
                         queryIdentifier: queryID, properties: codecs, propertyTitles: titles)
        }
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
