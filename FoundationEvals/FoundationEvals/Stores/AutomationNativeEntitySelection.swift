#if os(macOS)
import Foundation
import IntentsAutomationCore

typealias AutomationNativeEntityQueryExecutor = @Sendable (AutomationPreparedApplication, ApplicationSurfaceCatalog.Entity, String, RunApproval, String, Bool, URL) async throws -> AutomationEntityQueryResult

enum AutomationNativeEntitySelection {
    static func label(_ choice: AutomationQueryEntityChoice, entity: ApplicationSurfaceCatalog.Entity) -> String {
        choice.properties.sorted(by: { $0.key < $1.key }).compactMap { name, value in
            if case .text(let text) = value { return (entity.propertyTitles[name] ?? name) + ": " + text }
            if case .bool(let flag) = value { return (entity.propertyTitles[name] ?? name) + ": " + (flag ? "yes" : "no") }
            return nil
        }.joined(separator: " · ")
    }
}
#endif
