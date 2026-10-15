import Foundation

/// A recipe identity is exact-build and environment scoped. Locale is the explicitly
/// approved profile declaration; a recipe does not discover or change device locale.
public struct AutomationRecipeContext: Codable, Equatable, Sendable {
    public let app: AppIdentity
    public let target: TargetIdentity
    public let environmentID: String
    public let catalogDigest: String
    public let hostDigest: String
    public let localeIdentifier: String
    public let uiRuntimeManifestDigest: String?
    public init(app: AppIdentity, target: TargetIdentity, environmentID: String, catalogDigest: String,
                hostDigest: String, localeIdentifier: String, uiRuntimeManifestDigest: String? = nil) {
        self.app = app; self.target = target; self.environmentID = environmentID
        self.catalogDigest = catalogDigest; self.hostDigest = hostDigest; self.localeIdentifier = localeIdentifier
        self.uiRuntimeManifestDigest = uiRuntimeManifestDigest
    }
    func validate() throws {
        guard [app.productDigest ?? "", catalogDigest, hostDigest].allSatisfy({ $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }),
              uiRuntimeManifestDigest == nil || uiRuntimeManifestDigest?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              !environmentID.isEmpty, !localeIdentifier.isEmpty, localeIdentifier.utf16.count <= 128 else {
            throw AutomationContractError.missingEvidence("Recipe needs exact product, schema, host, environment and declared locale identities")
        }
    }
    public static func catalogDigest(_ catalog: ApplicationSurfaceCatalog) throws -> String {
        let json = try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(catalog))
        return AutomationArtifactRegistry.digest(try AutomationCanonicalJSON.encode(json))
    }
}
