import Foundation

/// Reusable input/navigation data with historical evidence links. Decoding this
/// value cannot restore live qualification, fixture ownership, or run approval.
public struct AutomationSavedNavigationSetupRecipe: Codable, Equatable, Sendable {
    public let context: AutomationRecipeContext
    public let qualificationAttemptIDs: [String]
    public let qualificationReportDigests: [String]
    let fixtureDigest: String
    let segmentID: String
    let operations: [AutomationUIProgram.Operation]

    func validate() throws {
        try context.validate()
        let isDigest: (String) -> Bool = { $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
        guard qualificationAttemptIDs.count == 2, Set(qualificationAttemptIDs).count == 2,
              qualificationAttemptIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }),
              qualificationReportDigests.count == 2, qualificationReportDigests.allSatisfy(isDigest),
              isDigest(fixtureDigest), AutomationHostProgram.identifier(segmentID),
              (2...30).contains(operations.count), operations.last?.kind == .assertEndpoint,
              operations.dropLast().allSatisfy({ [.tap, .fillBinding, .scroll].contains($0.kind) }),
              operations.allSatisfy({ $0.goal == nil && $0.property == nil }),
              operations.compactMap(\.locator).allSatisfy({ locator in
                  locator.value.range(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#, options: .regularExpression) == nil
              }) else { throw AutomationContractError.missingEvidence("Malformed saved setup proposal or qualification references") }
        let bindings = Dictionary(operations.compactMap(\.binding).map { ($0, "fresh-input-validation") }, uniquingKeysWith: { first, _ in first })
        try AutomationUIProgram(operations: operations, bindings: bindings).validate(phase: .setup)
    }

    public func propose(plan: AutomationCase, context: AutomationRecipeContext) throws -> AutomationCase {
        try validate(); try context.validate()
        guard context == self.context, plan.app == context.app, plan.target == context.target,
              plan.environmentID == context.environmentID, plan.provenance["ui.locale"] == context.localeIdentifier,
              try AutomationQualifiedFreshFixture.digest(plan: plan) == fixtureDigest,
              let index = plan.setup.firstIndex(where: { $0.id == segmentID }), let program = plan.setup[index].uiProgram else {
            throw AutomationContractError.missingEvidence("Saved setup context or approved fixture contract changed")
        }
        var proposal = plan
        proposal.setup[index].uiProgram = .init(operations: operations, bindings: program.bindings, timeoutMilliseconds: program.timeoutMilliseconds)
        var validation = proposal.setup[index].uiProgram!
        for key in proposal.setup[index].attemptTextBindings?.keys ?? Dictionary<String, String>().keys { validation.bindings[key] = "fresh-input-validation" }
        try validation.validate(phase: .setup)
        return proposal
    }
}

/// A bounded private archive. Invalid or unknown data is never silently replaced.
public struct AutomationNavigationSetupRecipeStore: Sendable {
    private struct Archive: Codable { var version = 1; let recipes: [AutomationSavedNavigationSetupRecipe] }
    private let file: AutomationDurableFile
    public init(supportRoot: URL) throws {
        file = try .init(url: supportRoot.appendingPathComponent("learned-setup-recipes.json"), maximumBytes: 524_288)
    }
    public func read(context: AutomationRecipeContext) throws -> AutomationSavedNavigationSetupRecipe? {
        try context.validate()
        return try readAll().first { $0.context == context }
    }
    public func save(_ recipe: AutomationSavedNavigationSetupRecipe) throws {
        try recipe.validate()
        try file.withLock {
            let recipes = Array(([recipe] + (try readAll()).filter { $0.context != recipe.context }).prefix(8))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try file.write(encoder.encode(Archive(recipes: recipes)))
        }
    }
    private func readAll() throws -> [AutomationSavedNavigationSetupRecipe] {
        guard let data = try file.read() else { return [] }
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        guard archive.version == 1, archive.recipes.count <= 8 else { throw AutomationContractError.invalidIdentity }
        try archive.recipes.forEach { try $0.validate() }
        for index in archive.recipes.indices {
            guard !archive.recipes.prefix(index).contains(where: { $0.context == archive.recipes[index].context }) else { throw AutomationContractError.invalidIdentity }
        }
        return archive.recipes
    }
}
