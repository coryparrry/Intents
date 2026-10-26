import Foundation
import CoreFoundation

extension MacIntentCatalog {
    /// Compiled metadata is a best-effort discovery index, not proof that the
    /// system runtime can invoke an action. Apple does not expose iterable definitions.
    /// - Returns: Discovered actions bound to a captured identity of the compiled native Mac app.
    /// - Throws: Invalid bundle, unavailable/unsupported metadata, changed build evidence, or file-read errors.
    public static func load(appURL: URL) throws -> MacIntentCatalog {
        let appURL = appURL.standardizedFileURL.resolvingSymlinksInPath()
        guard appURL.pathExtension == "app",
              let bundle = Bundle(url: appURL), let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path),
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              let identifier = bundle.bundleIdentifier, !identifier.isEmpty else {
            throw MacIntentTestingError("Choose a compiled macOS .app with a bundle identifier and executable.")
        }
        guard FileManager.default.fileExists(atPath: appURL.appendingPathComponent("Contents/MacOS").path),
              bundle.object(forInfoDictionaryKey: "LSRequiresIPhoneOS") as? Bool != true else {
            throw MacIntentTestingError("Only native macOS application bundles are supported.")
        }
        let metadata = appURL.appendingPathComponent("Contents/Resources/Metadata.appintents/extract.actionsdata")
        guard let data = try? Data(contentsOf: metadata), data.count <= 16 * 1024 * 1024 else {
            throw MacIntentTestingError("The app has no readable compiled App Intents metadata (extract.actionsdata). Rebuild it with Xcode 27.")
        }
        let decoded = try decode(data: data, bundleIdentifier: identifier, appURL: appURL)
        let identity = try MacIntentProductIdentity.capture(appURL)
        guard try Data(contentsOf: metadata) == data else {
            throw MacIntentTestingError("The app's metadata changed while its catalog was being read. Select the app again.")
        }
        return .init(bundleIdentifier: identifier, appURL: appURL, actions: decoded.actions, productIdentity: identity)
    }

    /// Parses version-one compiled action metadata, rejecting malformed actions, parameters, duplicates, or an empty catalog.
    static func decode(data: Data, bundleIdentifier: String, appURL: URL) throws -> MacIntentCatalog {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let definitions = root["actions"] as? [String: Any] else {
            throw MacIntentTestingError("Unsupported compiled App Intents metadata schema; expected version 1 and an actions object.")
        }
        var enums: [String: [String]] = [:]
        for item in root["enums"] as? [[String: Any]] ?? [] {
            guard let id = item["identifier"] as? String, let cases = item["cases"] as? [[String: Any]] else { continue }
            enums[id] = cases.compactMap { $0["identifier"] as? String }
        }
        var actions: [MacIntentAction] = []
        for key in definitions.keys.sorted() {
            guard let raw = definitions[key] as? [String: Any],
                  let id = raw["identifier"] as? String, id == key, !id.isEmpty,
                  let parameters = raw["parameters"] as? [[String: Any]] else {
                throw MacIntentTestingError("Malformed action metadata for \(key).")
            }
            var parsed: [MacIntentParameter] = []
            for p in parameters {
                guard let name = p["name"] as? String, !name.isEmpty,
                      let optional = p["isOptional"] as? Bool,
                      let valueType = p["valueType"] as? [String: Any] else {
                    throw MacIntentTestingError("Malformed parameter metadata in \(key).")
                }
                let enumID = ((valueType["linkEnumeration"] as? [String: Any])?["wrapper"] as? [String: Any])?["identifier"] as? String
                let metadata = p["typeSpecificMetadata"] as? [Any] ?? []
                let hasDefault = metadata.contains { ($0 as? String) == "LNValueTypeSpecificMetadataKeyDefaultValue" }
                parsed.append(.init(id: name, name: title(p["title"]) ?? name,
                                    type: enumID == nil ? typeName(valueType) : "Enum",
                                    required: !optional && !hasDefault,
                                    enumIdentifier: enumID, enumCases: enumID.flatMap { enums[$0] } ?? []))
            }
            guard Set(parsed.map(\.id)).count == parsed.count else { throw MacIntentTestingError("Duplicate parameter identifiers in \(key).") }
            actions.append(.init(id: id, title: title(raw["title"]) ?? id, parameters: parsed,
                                 outputType: typeName(raw["outputType"] as? [String: Any] ?? [:])))
        }
        guard !actions.isEmpty else { throw MacIntentTestingError("The app's compiled metadata contains no App Intent definitions.") }
        return .init(bundleIdentifier: bundleIdentifier, appURL: appURL, actions: actions)
    }

    /// Extracts the localization key used as a metadata title when that object is present.
    private static func title(_ raw: Any?) -> String? { (raw as? [String: Any])?["key"] as? String }
    /// Maps supported integral primitive type identifiers to scalar Swift types and labels other metadata unsupported.
    private static func typeName(_ raw: [String: Any]) -> String {
        guard raw.count == 1, let primitive = raw["primitive"] as? [String: Any],
              let wrapper = primitive["wrapper"] as? [String: Any],
              let type = wrapper["typeIdentifier"] as? NSNumber,
              CFGetTypeID(type) != CFBooleanGetTypeID(),
              NSNumber(value: type.intValue) == type else { return "unsupported" }
        switch type.intValue {
        case 0: return "String"
        case 1: return "Bool"
        case 2: return "Int"
        case 7: return "Double"
        default: return "unsupported (primitive \(type))"
        }
    }
}
