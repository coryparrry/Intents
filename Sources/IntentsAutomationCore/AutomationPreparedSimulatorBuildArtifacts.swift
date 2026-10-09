import Foundation

/// Exact simulator build evidence, separate from the declared comparison contract.
public struct AutomationPreparedSimulatorBuildArtifacts: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var hostProductDigest: String
    public var xctestrunDigest: String
    public var catalogDigest: String
    public var catalogSurfaceDigest: String
    public var hostTemplateDigest: String

    func validate(plan: AutomationCase) throws {
        guard schemaVersion == 1, plan.target.kind == .simulator, plan.app.platform == "ios",
              plan.app.productDigest != nil, plan.app.canonicalBundlePath != nil,
              plan.preparedMacBuildArtifacts == nil,
              [hostProductDigest, xctestrunDigest, catalogDigest, catalogSurfaceDigest, hostTemplateDigest].allSatisfy({
                  $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
              }), ["ui.preparedHostDigest", "ui.preparedXctestrunDigest", "ui.preparedCatalogDigest", "ui.hostTemplateDigest"].allSatisfy({ plan.provenance[$0] == nil }),
              plan.provenance["catalog"] == nil || plan.provenance["catalog"] == catalogDigest else {
            throw AutomationContractError.invalidPlan("Versioned simulator build artifacts require exact identities and one evidence representation")
        }
    }
    var comparisonProjection: Self {
        var value = self
        value.hostProductDigest = String(repeating: "0", count: 64)
        value.xctestrunDigest = value.hostProductDigest; value.catalogDigest = value.hostProductDigest
        return value
    }
#if os(macOS)
    public init(prepared: AutomationPreparedApplication) throws {
        guard prepared.host.target.kind == .simulator, prepared.host.app.platform == "ios",
              prepared.catalog.app == prepared.host.app,
              prepared.host.subjectProductPath == prepared.host.app.canonicalBundlePath,
              prepared.host.app.sourceManifestDigest == (try prepared.source.digest),
              prepared.generatedHost.configuration == prepared.host.app.configuration else {
            throw AutomationContractError.conflictingOperation
        }
        hostProductDigest = prepared.host.hostProductDigest; xctestrunDigest = prepared.host.xctestrunDigest
        catalogDigest = try AutomationRecipeContext.catalogDigest(prepared.catalog)
        hostTemplateDigest = prepared.generatedHost.templateDigest
        var surface = prepared.catalog
        surface.app.canonicalBundlePath = nil; surface.app.productDigest = nil; surface.app.productDigestVersion = nil
        surface.app.codeDirectoryIdentity = nil; surface.app.sourceManifestDigest = nil; surface.app.sourceSyntaxIndexDigest = nil
        surface.app.provenanceStrength = "comparisonContract"
        // Source locations and reconciliation diagnostics identify a build, not its declared schema.
        surface.sourceGraphDigest = nil; surface.sourceSyntaxIndexDigest = nil; surface.gaps = []
        for index in surface.systemActions.indices {
            surface.systemActions[index].sourceCandidates = nil
            surface.systemActions[index].sourceReconciliation = nil
        }
        catalogSurfaceDigest = try AutomationRecipeContext.catalogDigest(surface)
    }
#endif
}
