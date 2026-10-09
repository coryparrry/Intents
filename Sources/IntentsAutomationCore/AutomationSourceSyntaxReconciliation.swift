import Foundation

public enum AutomationSourceSyntaxReconciliation {
    public static func apply(_ index: AutomationSourceSyntaxIndex, graph: AutomationSourceGraph,
                             to catalog: ApplicationSurfaceCatalog) throws -> ApplicationSurfaceCatalog {
        guard index.schemaVersion == 2, graph.schemaVersion == AutomationSourceGraph.currentSchemaVersion, index.coverage == "partial", index.sourceManifestDigest == graph.sourceManifestDigest,
              index.sourceGraphDigest == (try graph.digest), catalog.app.sourceManifestDigest == graph.sourceManifestDigest,
              catalog.app.sourceSyntaxIndexDigest == (try index.digest), index.inputs.count <= 1000, index.declarations.count <= 5000 else { throw AutomationContractError.conflictingOperation }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try index.compilationConditions?.validate(graph: graph)
        for input in index.inputs {
            guard graph.admitsSwiftDeclarations(role: input.role), let expected = graph.inputs.first(where: { $0.owner == input.owner && $0.relativePath == input.relativePath && $0.role == input.role }),
                  try encoder.encode(expected) == encoder.encode(input) else { throw AutomationContractError.conflictingOperation }
        }
        for declaration in index.declarations {
            guard declaration.line > 0, declaration.column.map({ $0 > 0 }) == true, declaration.qualifiedName?.isEmpty == false,
                  index.inputs.contains(where: { $0.relativePath == declaration.relativePath && $0.owner == declaration.owner }) else { throw AutomationContractError.conflictingOperation }
        }
        var result = catalog; result.sourceSyntaxIndexDigest = try index.digest
        for position in result.systemActions.indices {
            let type = result.systemActions[position].typeName
            let candidates = index.declarations.filter { declaration in
                guard declaration.owner == graph.projectRelativePath + "#" + graph.targetID,
                      AutomationSourceCompilationConditions.resolve(declaration, facts: index.compilationConditions) == true,
                      let qualified = declaration.qualifiedName else { return false }
                let moduleMatch = catalog.app.owningModule.map { type == $0 + "." + qualified } ?? false
                return (type == qualified || moduleMatch) && declaration.protocols.contains(where: { $0 == "AppIntent" || $0 == "AppIntents.AppIntent" })
            }
            result.systemActions[position].sourceCandidates = candidates
            result.systemActions[position].sourceReconciliation = candidates.isEmpty ? "unresolved" : candidates.count == 1 ? "syntaxCandidate" : "ambiguous"
        }
        result.gaps = Array(Set(result.gaps.map { $0.replacingOccurrences(of: "and SwiftSyntax reconciliation are unavailable", with: "remain unresolved") } + index.gaps + ["Dependency source candidates require independently resolved owning module identities."])).sorted()
        result.systemDiscoveryComplete = false
        return result
    }
}
