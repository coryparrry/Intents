import Foundation

/// Inputs supplied by the native approval flow, scoped to the exact selected build,
/// declarations and environment. This data never grants execution authority.
public struct AutomationFirstRunInputEvidence: Sendable {
    public var app: AppIdentity
    public var target: TargetIdentity
    public var environmentID: String
    public var catalogDigest: String
    public var inputs: [String: [String: AutomationActionInput]]
    public var recipes: [String: AutomationFirstRunRecipeInput]
    public var savedCases: [AutomationFrozenCase]
    public var runtimeContext: AutomationRecipeContext?
    public var unavailableActions: [String: String] = [:]
    #if os(macOS)
    /// Only the live query runner can issue these choices. Each attempt re-resolves them.
    public var entitySelections: [String: [String: AutomationQueryEntityChoice]] = [:]
    #endif

    public init(app: AppIdentity, target: TargetIdentity, environmentID: String, catalogDigest: String,
                inputs: [String: [String: AutomationActionInput]] = [:],
                recipes: [String: AutomationFirstRunRecipeInput] = [:],
                savedCases: [AutomationFrozenCase] = [], runtimeContext: AutomationRecipeContext? = nil) {
        self.app = app; self.target = target; self.environmentID = environmentID
        self.catalogDigest = catalogDigest; self.inputs = inputs; self.recipes = recipes
        self.savedCases = savedCases; self.runtimeContext = runtimeContext
    }

    func matches(catalog: ApplicationSurfaceCatalog, approval: RunApproval) throws -> Bool {
        let observedCatalogDigest = try AutomationRecipeContext.catalogDigest(catalog)
        return app == catalog.app && target == approval.target && environmentID == approval.environmentID
            && catalogDigest == observedCatalogDigest
    }
}

/// A saved qualified producer plus a freshly approved real input. The compiler
/// replays the producer and binds its fresh observation rather than a cached output.
public struct AutomationFirstRunRecipeInput: Sendable {
    public var recipe: AutomationQualifiedSetupRecipe
    public var context: AutomationRecipeContext
    public var text: String
    public var consumingParameter: String
    public init(recipe: AutomationQualifiedSetupRecipe, context: AutomationRecipeContext,
                text: String, consumingParameter: String) {
        self.recipe = recipe; self.context = context; self.text = text
        self.consumingParameter = consumingParameter
    }
}
