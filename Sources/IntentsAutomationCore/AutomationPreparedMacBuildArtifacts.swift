import Foundation

/// Exact retained build evidence; only its per-build fingerprints vary in a comparison.
public struct AutomationPreparedMacBuildArtifacts: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var hostProductDigest: String
    public var xctestrunDigest: String
    public var catalogDigest: String
    public var catalogSurfaceDigest: String
    public var hostTemplateDigest: String

    func validate(plan: AutomationCase) throws {
        guard schemaVersion == 1, plan.target.kind == .nativeMac, plan.app.platform == "macos", plan.app.productDigestVersion == 2,
              plan.app.productDigest != nil, plan.app.canonicalBundlePath != nil,
              [hostProductDigest, xctestrunDigest, catalogDigest, catalogSurfaceDigest, hostTemplateDigest].allSatisfy({
                  $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
              }), ["apple.macHostProductDigest", "apple.macXctestrunDigest", "ui.preparedHostDigest", "ui.preparedXctestrunDigest", "ui.preparedCatalogDigest"].allSatisfy({ plan.provenance[$0] == nil }) else {
            throw AutomationContractError.invalidPlan("Versioned Mac build artifacts require exact identities and one evidence representation")
        }
    }
    var comparisonProjection: Self {
        var value = self
        value.hostProductDigest = String(repeating: "0", count: 64)
        value.xctestrunDigest = value.hostProductDigest; value.catalogDigest = value.hostProductDigest
        return value
    }
#if os(macOS)
    static func validateSelection(_ prepared: AutomationPreparedApplication, plan: AutomationCase) throws {
        try AutomationApplicationSubject.prepared(prepared).validate(plan: plan)
        guard prepared.host.target.kind == .nativeMac, prepared.catalog.app == prepared.host.app,
              prepared.host.app.sourceManifestDigest == (try prepared.source.digest),
              prepared.host.app.canonicalBundlePath == prepared.host.subjectProductPath else { throw AutomationContractError.conflictingOperation }
        _ = try AutomationMacAssociatedHostReleaseVerifier.profile(prepared.host)
        if let artifacts = plan.preparedMacBuildArtifacts {
            guard artifacts == (try Self(prepared: prepared)) else { throw AutomationContractError.conflictingOperation }
        }
        let product = URL(fileURLWithPath: prepared.host.subjectProductPath), test = URL(fileURLWithPath: prepared.host.xctestrunPath)
        guard try AutomationPath.canonical(product).path == product.path, try AutomationPath.canonical(test).path == test.path,
              try AutomationProductDigest.compute(bundle: product, version: 2) == prepared.host.app.productDigest,
              AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(test, maximumBytes: 4 * 1024 * 1024)) == prepared.host.xctestrunDigest else {
            throw AutomationContractError.conflictingOperation
        }
    }
    public init(prepared: AutomationPreparedApplication) throws {
        guard prepared.host.target.kind == .nativeMac, prepared.catalog.app == prepared.host.app,
              prepared.generatedHost.configuration == prepared.host.app.configuration else { throw AutomationContractError.conflictingOperation }
        hostProductDigest = prepared.host.hostProductDigest; xctestrunDigest = prepared.host.xctestrunDigest
        catalogDigest = try AutomationRecipeContext.catalogDigest(prepared.catalog)
        hostTemplateDigest = prepared.generatedHost.templateDigest
        var surface = prepared.catalog
        surface.app.canonicalBundlePath = nil; surface.app.productDigest = nil; surface.app.productDigestVersion = nil
        surface.app.codeDirectoryIdentity = nil; surface.app.sourceManifestDigest = nil
        surface.app.sourceSyntaxIndexDigest = nil
        surface.app.provenanceStrength = "comparisonContract"
        // Source graphs/syntax identify the selected build, not the declared action/entity schema.
        surface.sourceGraphDigest = nil; surface.sourceSyntaxIndexDigest = nil
        for index in surface.systemActions.indices { surface.systemActions[index].sourceCandidates = nil }
        catalogSurfaceDigest = try AutomationRecipeContext.catalogDigest(surface)
    }
#endif
}
