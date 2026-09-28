import Foundation
import CryptoKit

struct FixtureNote: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var body: String
}

enum FixtureNotes {
    static let all = [
        FixtureNote(id: "packing-001", title: "Packing note", body: "Passport, blue charger, and rain jacket."),
        FixtureNote(id: "packing-002", title: "Packing notes", body: "Archive: beach towel and paperback."),
        FixtureNote(id: "garden-001", title: "Garden note", body: "Water the basil on Tuesday."),
        FixtureNote(id: "trip-2027", title: "Trip plan", body: "Train 218 leaves at 08:45 on 14 June 2027. Bring the red folder. The return train leaves at 19:10."),
        FixtureNote(id: "meeting-001", title: "Planning meeting", body: "The team agreed to ship the offline guide on Friday. Maya will review the screenshots; Theo will check the installation steps. The budget remains £240. No customer data will be used in the demo. The follow-up is scheduled for 3 July 2027."),
        FixtureNote(id: "short-001", title: "One-word reminder", body: "Umbrella.")
    ]

    static func note(id: String) -> FixtureNote? { all.first { $0.id == id } }

    static func contentDigest(_ note: FixtureNote) -> String {
        let bytes = Data("\(note.id)\u{0}\(note.title)\u{0}\(note.body)".utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func resolve(prompt: String) throws -> FixtureNote {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func containsWhole(_ value: String) -> Bool {
            let escaped = NSRegularExpression.escapedPattern(for: value.lowercased())
            return text.range(of: "(?<![[:alnum:]-])\(escaped)(?![[:alnum:]-])", options: .regularExpression) != nil
        }
        let matches = all.filter { note in
            containsWhole(note.id) || containsWhole(note.title)
        }
        guard matches.count == 1, let note = matches.first else {
            throw FixtureNoteResolutionError.invalidOrAmbiguous
        }
        return note
    }
}

enum FixtureNoteResolutionError: LocalizedError {
    case invalidOrAmbiguous
    var errorDescription: String? { "Name exactly one synthetic note by stable ID or full title." }
}

struct FixtureSummaryReceipt: Codable, Sendable {
    var noteID: String
    var sourceContentDigest: String
    var summary: String
    var context: String
    var completionID: String
    var route: String
    var subjectCaseID: UUID?
    var subjectAttemptID: UUID?
}

enum FixtureState {
    static let selectedNoteKey = "intent-lab.selected-note-id"
    static let mutationCountKey = "intent-lab.mutation-count"
    static let activeContextKey = "intent-lab.active-context"
    static let observedContextKey = "intent-lab.observed-context"
    static let eventKey = "intent-lab.last-event"
    static let summaryReceiptKey = "intent-lab.summary-receipt"

    static func reset() {
        UserDefaults.standard.set("none", forKey: selectedNoteKey)
        UserDefaults.standard.set(0, forKey: mutationCountKey)
        UserDefaults.standard.removeObject(forKey: observedContextKey)
        UserDefaults.standard.removeObject(forKey: eventKey)
        UserDefaults.standard.removeObject(forKey: summaryReceiptKey)
    }

    static func select(noteID: String) {
        UserDefaults.standard.set(noteID, forKey: selectedNoteKey)
    }

    static func beginSummaryAttempt(noteID: String) {
        let defaults = UserDefaults.standard
        defaults.set(noteID, forKey: selectedNoteKey)
        defaults.removeObject(forKey: summaryReceiptKey)
        defaults.removeObject(forKey: eventKey)
        defaults.removeObject(forKey: observedContextKey)
    }

    static func begin(context: String) {
        UserDefaults.standard.set(context, forKey: activeContextKey)
    }

    static func record(event: String) {
        let defaults = UserDefaults.standard
        defaults.set(defaults.string(forKey: activeContextKey) ?? "unknown", forKey: observedContextKey)
        defaults.set(event, forKey: eventKey)
    }

    @discardableResult
    static func publishSummary(
        _ summary: String,
        for note: FixtureNote,
        route: String,
        subjectCaseID: UUID? = nil,
        subjectAttemptID: UUID? = nil
    ) throws -> FixtureSummaryReceipt {
        let defaults = UserDefaults.standard
        let receipt = FixtureSummaryReceipt(
            noteID: note.id,
            sourceContentDigest: FixtureNotes.contentDigest(note),
            summary: summary,
            context: defaults.string(forKey: activeContextKey) ?? "app-\(UUID().uuidString)",
            completionID: UUID().uuidString,
            route: route,
            subjectCaseID: subjectCaseID,
            subjectAttemptID: subjectAttemptID
        )
        let encoded = try JSONEncoder().encode(receipt)
        defaults.set(note.id, forKey: selectedNoteKey)
        defaults.set(encoded, forKey: summaryReceiptKey)
        record(event: "\(route):\(note.id)")
        return receipt
    }
}
