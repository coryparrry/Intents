import AppIntents

struct NoteEntity: AppEntity, Identifiable {
    var id: String
    @Property(title: "Title") var title: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Synthetic note"
    static let defaultQuery = NoteEntityQuery()

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }

    init(_ note: FixtureNote) {
        id = note.id
        title = note.title
    }

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

struct NoteEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [NoteEntity] {
        FixtureNotes.all.filter { identifiers.contains($0.id) }.map(NoteEntity.init)
    }

    func entities(matching string: String) async throws -> [NoteEntity] {
        FixtureNotes.all.filter { $0.title.localizedCaseInsensitiveContains(string) }.map(NoteEntity.init)
    }

    func suggestedEntities() async throws -> [NoteEntity] { FixtureNotes.all.map(NoteEntity.init) }
}

struct OpenNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Open synthetic note"
    static let description = IntentDescription("Opens an Intent Lab fixture note by stable identifier.")
    static let openAppWhenRun = true

    @Parameter(title: "Note") var note: NoteEntity

    init() {}

    init(note: NoteEntity) {
        self.note = note
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard FixtureNotes.note(id: note.id) != nil else { throw FixtureIntentError.missingNote }
        FixtureState.select(noteID: note.id)
        FixtureState.record(event: "OpenNoteIntent:\(note.id)")
        return .result(value: note.id)
    }
}

struct SummarizeNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize synthetic note"
    static let openAppWhenRun = true

    @Parameter(title: "Note") var note: NoteEntity

    init() {}

    init(note: NoteEntity) {
        self.note = note
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let source = FixtureNotes.note(id: note.id) else { throw FixtureIntentError.missingNote }
        FixtureState.beginSummaryAttempt(noteID: source.id)
        let summary = try await SummaryService.summarize(source)
        try FixtureState.publishSummary(summary, for: source, route: "SummarizeNoteIntent")
        return .result(value: summary)
    }
}

// Give each fixed command its own indexed action. The generic intents stay
// available for saved shortcuts and entity selection, and own the production work.
struct OpenPackingNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Open packing note"
    static let description = IntentDescription("Opens the synthetic packing note without asking which note to use.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await OpenNoteIntent(note: PackingNoteShortcut.note).perform()
    }
}

struct SummarizePackingNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize packing note"
    static let description = IntentDescription("Generates a summary of the synthetic packing note using the production summary service.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await SummarizeNoteIntent(note: PackingNoteShortcut.note).perform()
    }
}

private enum PackingNoteShortcut {
    static var note: NoteEntity { NoteEntity(id: "packing-001", title: "Packing note") }
}

struct FixtureShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenPackingNoteIntent(),
            phrases: ["Open the packing note in \(.applicationName)"],
            shortTitle: "Open packing note",
            systemImageName: "note.text"
        )
        AppShortcut(
            intent: OpenNoteIntent(),
            phrases: ["Open a note in \(.applicationName)"],
            shortTitle: "Open note",
            systemImageName: "note.text"
        )
        AppShortcut(
            intent: SummarizePackingNoteIntent(),
            phrases: ["Summarize the packing note in \(.applicationName)"],
            shortTitle: "Summarize packing note",
            systemImageName: "text.quote"
        )
        AppShortcut(
            intent: SummarizeNoteIntent(),
            phrases: ["Summarize a note in \(.applicationName)"],
            shortTitle: "Summarize note",
            systemImageName: "text.quote"
        )
    }
}

enum FixtureIntentError: LocalizedError {
    case missingNote
    var errorDescription: String? { "The synthetic note no longer exists." }
}
