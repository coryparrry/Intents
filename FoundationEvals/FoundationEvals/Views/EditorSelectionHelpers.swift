import Foundation

/// Keeps a selection while its ID is present, otherwise selects the first available ID.
func repairEditorSelection<ID: Equatable>(_ selected: ID?, ids: [ID], update: (ID?) -> Void) {
    if selected.map({ ids.contains($0) }) != true {
        update(ids.first)
    }
}

/// Returns the first unused numbered name, filling gaps in the sequence.
func firstAvailableNumberedName(prefix: String, existing: Set<String>) -> String {
    (1...).lazy.map { "\(prefix)\($0)" }.first { !existing.contains($0) }!
}
