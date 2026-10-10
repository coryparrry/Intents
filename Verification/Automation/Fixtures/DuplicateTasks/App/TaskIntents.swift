import AppIntents
import Foundation

struct TaskEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Task"
    static let defaultQuery = TaskQuery()
    var id: String
    @Property(title: "Title") var title: String
    @Property(title: "Account") var owner: String
    @Property(title: "Completed") var completed: Bool
    @Property(title: "Control") var control: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(title)", subtitle: "\(owner)") }
    init(_ record: TaskRecord, control: TaskControl) {
        id = record.id; title = record.title; owner = record.owner; completed = record.completed
        self.control = control.rawValue
    }
}
struct TaskQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [TaskEntity] {
        let document = try await TaskRepository.shared.persistedDocument()
        return document.records.filter { identifiers.contains($0.id) }.map { TaskEntity($0, control: document.control) }
    }
    func entities(matching string: String) async throws -> [TaskEntity] {
        let document = try await TaskRepository.shared.persistedDocument()
        return document.records.filter { $0.title.localizedCaseInsensitiveContains(string) }.map { TaskEntity($0, control: document.control) }
    }
    func suggestedEntities() async throws -> [TaskEntity] {
        let document = try await TaskRepository.shared.persistedDocument()
        return document.records.map { TaskEntity($0, control: document.control) }
    }
}
struct CompleteTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete task"
    static let openAppWhenRun = false
    @Parameter(title: "Task") var task: TaskEntity
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await TaskRepository.shared.complete(id: task.id)
        return .result(dialog: "Task marked complete.")
    }
}
