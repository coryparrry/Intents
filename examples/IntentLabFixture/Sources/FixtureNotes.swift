import Foundation

struct FixtureNote: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var body: String
}

enum FixtureNotes {
    static let all = [
        FixtureNote(id: "packing-001", title: "Packing note", body: "Passport, blue charger, and rain jacket."),
        FixtureNote(id: "packing-002", title: "Packing notes", body: "Archive: beach towel and paperback."),
        FixtureNote(id: "garden-001", title: "Garden note", body: "Water the basil on Tuesday.")
    ]

    static func note(id: String) -> FixtureNote? { all.first { $0.id == id } }
}

enum FixtureState {
    static let selectedNoteKey = "intent-lab.selected-note-id"
    static let mutationCountKey = "intent-lab.mutation-count"
    static let activeContextKey = "intent-lab.active-context"
    static let observedContextKey = "intent-lab.observed-context"
    static let eventKey = "intent-lab.last-event"

    static func reset() {
        UserDefaults.standard.set("none", forKey: selectedNoteKey)
        UserDefaults.standard.set(0, forKey: mutationCountKey)
        UserDefaults.standard.removeObject(forKey: observedContextKey)
        UserDefaults.standard.removeObject(forKey: eventKey)
    }

    static func select(noteID: String) {
        UserDefaults.standard.set(noteID, forKey: selectedNoteKey)
    }

    static func begin(context: String) {
        UserDefaults.standard.set(context, forKey: activeContextKey)
    }

    static func record(event: String) {
        let defaults = UserDefaults.standard
        defaults.set(defaults.string(forKey: activeContextKey) ?? "unknown", forKey: observedContextKey)
        defaults.set(event, forKey: eventKey)
    }
}
