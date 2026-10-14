import Foundation
import CoreFoundation

public struct ApplicationSurfaceCatalog: Codable, Equatable, Sendable {
    public struct SystemAction: Codable, Equatable, Sendable, Identifiable {
        public struct Parameter: Codable, Equatable, Sendable {
            public var name: String
            public var family: String?
            public var optional: Bool
            public var typeID: String? = nil
            public var defaultValue: AutomationValue? = nil
        }
        public var id: String
        public var typeName: String
        public var title: String
        public var parameters: [Parameter]
        public var parametersComplete: Bool
        public var compiled: Bool
        public var registered: Bool
        public var executed: Bool
        public var resultFamily: String? = nil
        public var sourceCandidates: [AutomationSourceDeclaration]? = nil
        public var sourceReconciliation: String? = nil
    }
    public var app: AppIdentity
    public var systemActions: [SystemAction]
    public var systemDiscoveryComplete: Bool
    public var uiDiscoveryComplete: Bool
    public var gaps: [String]
    public var entities: [Entity]? = nil
    public var enumerations: [Enumeration]? = nil
    public var sourceGraphDigest: String? = nil
    public var sourceSyntaxIndexDigest: String? = nil
}

/// Reads the supported metadata schema independently of the Xcode build that emitted it.
public enum AutomationSurfaceCatalogReader {
    public static func read(app: AppIdentity, product: URL) throws -> ApplicationSurfaceCatalog {
        guard app.productDigest == (try AutomationProductDigest.compute(bundle: product, version: app.productDigestVersion)) else { throw AutomationContractError.conflictingOperation }
        let relative = (app.platform == "macos" ? "Contents/Resources/" : "") + "Metadata.appintents/extract.actionsdata"
        guard FileManager.default.fileExists(atPath: product.appendingPathComponent(relative).path) else {
            return .init(app: app, systemActions: [], systemDiscoveryComplete: false, uiDiscoveryComplete: false,
                         gaps: ["Built system metadata is unavailable. External UI checks remain separate."])
        }
        let data = try AutomationProductDigest.readFile(bundle: product, relativePath: relative, maximumBytes: 16 * 1024 * 1024, version: app.productDigestVersion, expectedDigest: app.productDigest)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let actions = root["actions"] as? [String: [String: Any]], actions.count <= 1000 else {
            return .init(app: app, systemActions: [], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: ["Unknown built metadata format; no empty-catalog or runtime-eligibility claim is made."])
        }
        let generator = root["generator"] as? [String: Any]
        let generatorVersion = (generator?["version"] as? String).map { String($0.prefix(128)) } ?? "unknown"
        let entities = AutomationEntityMetadata.read(root)
        let enumerations = AutomationCodecMetadata.enumerations(root)
        var result: [ApplicationSurfaceCatalog.SystemAction] = [], gaps = ["Built with Xcode " + generatorVersion + "; metadata parsed best-effort.", "Runtime registration, query execution and source graph reconciliation remain independent checks."]
        var unsupportedInputCount = 0
        for (id, action) in actions.sorted(by: { $0.key < $1.key }) {
            guard AutomationHostProgram.identifier(id), action["identifier"] as? String == id,
                  let type = action["fullyQualifiedTypeName"] as? String,
                  let parameters = action["parameters"] as? [[String: Any]], parameters.count <= 50 else { gaps.append("An action has an unsupported metadata shape."); continue }
            var values: [ApplicationSurfaceCatalog.SystemAction.Parameter] = [], parametersComplete = true
            for parameter in parameters {
                guard let name = parameter["name"] as? String, AutomationHostProgram.identifier(name), let optional = parameter["isOptional"] as? Bool else { parametersComplete = false; gaps.append("An input has an unsupported metadata shape."); continue }
                let valueType = parameter["valueType"] as? [String: Any]
                let primitive = AutomationEntityMetadata.primitive(valueType)
                let entityID = AutomationEntityMetadata.entityType(valueType)
                let entity = entities.first { $0.typeID == entityID }
                let enumID = AutomationCodecMetadata.enumerationType(valueType)
                let enumeration = enumerations.first { $0.typeID == enumID }
                let family = AutomationCodecMetadata.inputPrimitiveFamily(primitive) ?? (entity != nil ? "entity" : enumeration != nil ? "enum" : AutomationCodecMetadata.duration(valueType) ? "duration" : AutomationCodecMetadata.intentFile(valueType) ? "intentFile" : AutomationCodecMetadata.arrayFamily(valueType))
                var declaration = ApplicationSurfaceCatalog.SystemAction.Parameter(name: name, family: family, optional: optional, typeID: entity?.typeID ?? enumeration?.typeID)
                declaration.defaultValue = AutomationCodecMetadata.defaultValue(parameter, declaration: declaration, enumerations: enumerations)
                values.append(declaration)
                if family == nil {
                    parametersComplete = false
                    unsupportedInputCount += 1
                    if unsupportedInputCount <= 50 { gaps.append("Input " + name + " in " + id + " uses an unsupported value type.") }
                }
            }
            if Set(values.map(\.name)).count != values.count { parametersComplete = false; gaps.append("An action has duplicate input names.") }
            let title = (action["title"] as? [String: Any])?["key"] as? String ?? id
            var declared = ApplicationSurfaceCatalog.SystemAction(id: id, typeName: type, title: title, parameters: values, parametersComplete: parametersComplete, compiled: true, registered: false, executed: false)
            declared.resultFamily = action["outputType"] == nil ? "noValue" : (AutomationCodecMetadata.primitiveFamily(AutomationEntityMetadata.primitive(action["outputType"] as? [String: Any])) ?? (AutomationCodecMetadata.duration(action["outputType"] as? [String: Any]) ? "duration" : AutomationCodecMetadata.intentFile(action["outputType"] as? [String: Any]) ? "intentFile" : AutomationCodecMetadata.arrayFamily(action["outputType"] as? [String: Any], input: false)))
            if values.contains(where: { $0.family == "url" }) || declared.resultFamily == "url" {
                gaps.append("URL references in " + id + " support exact HTTP(S) values only; file transfer and runtime conversion qualification remain unavailable.")
            }
            if action["outputType"] != nil, declared.resultFamily == nil { gaps.append("Result projection is unsupported for " + id + "; invocation can run without reading its result.") }
            result.append(declared)
        }
        if unsupportedInputCount > 50 { gaps.append("Additional unsupported inputs: " + String(unsupportedInputCount - 50) + ".") }
        return .init(app: app, systemActions: result, systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: gaps, entities: entities, enumerations: enumerations)
    }
}
