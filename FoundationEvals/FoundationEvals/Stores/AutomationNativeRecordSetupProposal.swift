#if os(macOS)
import Foundation
import IntentsAutomationCore

/// Type metadata can select an unambiguous field, but cannot establish the
/// app's business outcome, valid input values or visible UI controls.
struct AutomationNativeRecordSetupProposal {
    let entity: ApplicationSurfaceCatalog.Entity
    let nameFields: [String]
    let stateFields: [String]

    init?(catalog: ApplicationSurfaceCatalog, actionID: String) {
        let actions = catalog.systemActions.filter { $0.id == actionID }
        guard actions.count == 1, let action = actions.first,
              action.compiled, action.parametersComplete, action.parameters.count == 1,
              let parameter = action.parameters.first, parameter.family == "entity" else { return nil }
        let entities = (catalog.entities ?? []).filter { $0.typeID == parameter.typeID }
        guard entities.count == 1, let entity = entities.first else { return nil }
        let names = entity.properties.keys.filter { entity.properties[$0] == "text" }.sorted()
        let states = entity.properties.keys.filter { entity.properties[$0] == "bool" }.sorted()
        guard !names.isEmpty, !states.isEmpty else { return nil }
        self.entity = entity
        nameFields = names
        stateFields = states
    }

    var proposedNameField: String? { nameFields.count == 1 ? nameFields.first : nil }
    var proposedStateField: String? { stateFields.count == 1 ? stateFields.first : nil }

    static func title(for field: String, in entity: ApplicationSurfaceCatalog.Entity) -> String {
        let fields = entity.properties.keys.filter { entity.properties[$0] == entity.properties[field] }.sorted()
        let position = (fields.firstIndex(of: field) ?? 0) + 1
        if let title = entity.propertyTitles[field], !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let duplicates = fields.filter { entity.propertyTitles[$0] == title }
            return duplicates.count > 1 ? "\(title) (field \(position))" : title
        }
        return "\(entity.properties[field] == "bool" ? "Yes/no" : "Text") field \(position)"
    }
}

extension AppAutomationStore {
    var freshRecordSetupProposal: AutomationNativeRecordSetupProposal? {
        guard let catalog else { return nil }
        return .init(catalog: catalog, actionID: actionID)
    }

    /// Only fills untouched schema choices. Selection changes remain responsible
    /// for resetting old inputs; this never replaces an explicit developer choice.
    func applyFreshRecordSetupProposal() {
        guard !busy, let proposal = freshRecordSetupProposal else { return }
        var changed = false
        if freshNameProperty.isEmpty, let field = proposal.proposedNameField {
            freshNameProperty = field
            changed = true
        }
        if freshStateProperty.isEmpty, let field = proposal.proposedStateField {
            freshStateProperty = field
            changed = true
        }
        if changed { workflowSelectionChanged() }
    }
}
#endif
