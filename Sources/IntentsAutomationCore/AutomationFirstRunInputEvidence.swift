import Foundation

/// Inputs supplied by the native approval flow, scoped to the exact selected build,
/// declarations and environment. This data never grants execution authority.
public struct AutomationFirstRunInputEvidence: Sendable {
    public var app: AppIdentity
    public var target: TargetIdentity
    public var environmentID: String
    public var catalogDigest: String
    public var inputs: [String: [String: AutomationActionInput]]
    public var savedCases: [AutomationFrozenCase]
    public var runtimeContext: AutomationRecipeContext?
    public var unavailableActions: [String: String] = [:]
    #if os(macOS)
    /// Only the live query runner can issue these choices. Each attempt re-resolves them.
    public var entitySelections: [String: [String: AutomationQueryEntityChoice]] = [:]
    #endif

    public init(app: AppIdentity, target: TargetIdentity, environmentID: String, catalogDigest: String,
                inputs: [String: [String: AutomationActionInput]] = [:],
                savedCases: [AutomationFrozenCase] = [], runtimeContext: AutomationRecipeContext? = nil) {
        self.app = app; self.target = target; self.environmentID = environmentID
        self.catalogDigest = catalogDigest; self.inputs = inputs
        self.savedCases = savedCases; self.runtimeContext = runtimeContext
    }

    func matches(catalog: ApplicationSurfaceCatalog, approval: RunApproval) throws -> Bool {
        let observedCatalogDigest = try AutomationRecipeContext.catalogDigest(catalog)
        return app == catalog.app && target == approval.target && environmentID == approval.environmentID
            && catalogDigest == observedCatalogDigest
    }
}
