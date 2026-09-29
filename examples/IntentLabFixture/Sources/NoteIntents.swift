import AppIntents
import IntentLabContracts

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
        let action = FixtureState.beginProductionIntent(operationID: "OpenNoteIntent", noteID: note.id)
        do {
            guard FixtureNotes.note(id: note.id) != nil else { throw FixtureIntentError.missingNote }
            FixtureState.select(noteID: note.id)
            FixtureState.record(event: "OpenNoteIntent:\(note.id)")
            FixtureState.finishProductionIntent(action)
            return .result(value: note.id)
        } catch {
            FixtureState.finishProductionIntent(action, error: error)
            throw error
        }
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
        let action = FixtureState.beginProductionIntent(operationID: "SummarizeNoteIntent", noteID: note.id)
        do {
            guard let source = FixtureNotes.note(id: note.id) else { throw FixtureIntentError.missingNote }
            FixtureState.beginSummaryAttempt(noteID: source.id)
            let summary = try await FixtureActionContext.$parentKind.withValue(IntentLabActionKind.productionIntent.rawValue) {
                try await SummaryService.summarize(source)
            }
            try FixtureState.publishSummary(summary, for: source, route: "SummarizeNoteIntent")
            FixtureState.finishProductionIntent(action)
            return .result(value: summary)
        } catch {
            FixtureState.finishProductionIntent(action, error: error)
            throw error
        }
    }
}

struct FixtureShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenNoteIntent(note: NoteEntity(id: "packing-001", title: "Packing note")),
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
            intent: SummarizeNoteIntent(note: NoteEntity(id: "packing-001", title: "Packing note")),
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
