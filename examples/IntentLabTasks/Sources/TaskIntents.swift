import AppIntents
import Foundation

struct TaskEntity: AppEntity, Identifiable {
    var id: String
    @Property(title: "Task title") var title: String
    @Property(title: "Completed") var isComplete: Bool
    @Property(title: "Last updated") var updatedAt: Date
    @Property(title: "Invocation context") var invocationContext: String
    @Property(title: "Action receipt") var actionReceiptID: String
    @Property(title: "Integration context") var integrationContext: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Task"
    static let defaultQuery = TaskEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(isComplete ? "Complete" : "Incomplete")"
        )
    }

    init(snapshot: TaskSnapshot, integrationContext: String = "") {
        id = snapshot.id
        title = snapshot.title
        isComplete = snapshot.isComplete
        updatedAt = snapshot.updatedAt
        invocationContext = snapshot.invocationContext
        actionReceiptID = snapshot.actionReceiptID
        self.integrationContext = integrationContext
    }

    init(id: String, title: String, isComplete: Bool = false, updatedAt: Date = .distantPast) {
        self.id = id
        self.title = title
        self.isComplete = isComplete
        self.updatedAt = updatedAt
        invocationContext = ""
        actionReceiptID = ""
        integrationContext = ""
    }
}

struct TaskEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [TaskEntity] {
        let integrationContext = await TaskRepository.shared.integrationContextForEntity
        return try await TaskRepository.shared.persistedTasks(identifiers: identifiers).map {
            TaskEntity(snapshot: $0, integrationContext: integrationContext)
        }
    }

    func entities(matching string: String) async throws -> [TaskEntity] {
        let matchingIDs = try await TaskRepository.shared.tasks(matching: string).map(\.id)
        let integrationContext = await TaskRepository.shared.integrationContextForEntity
        return try await TaskRepository.shared.persistedTasks(identifiers: matchingIDs).map {
            TaskEntity(snapshot: $0, integrationContext: integrationContext)
        }
    }

    func suggestedEntities() async throws -> [TaskEntity] {
        let allIDs = try await TaskRepository.shared.tasks().map(\.id)
        let integrationContext = await TaskRepository.shared.integrationContextForEntity
        return try await TaskRepository.shared.persistedTasks(identifiers: allIDs).map {
            TaskEntity(snapshot: $0, integrationContext: integrationContext)
        }
    }
}

struct CompleteTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete task"
    static let description = IntentDescription("Marks a task complete in the task list.")
    static let openAppWhenRun = false

    @Parameter(title: "Task") var task: TaskEntity

    init() {}

    init(task: TaskEntity) {
        self.task = task
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let receipt = try await TaskRepository.shared.complete(
            taskID: task.id,
            expectedIntegrationContext: task.integrationContext
        )
        return .result(value: receipt.response)
    }
}

#if INTENT_LAB_TESTING
/// Test-only probe for validating context-bound actions without using an entity query.
struct AttemptContextTaskMutationTestIntent: AppIntent {
    static let title: LocalizedStringResource = "Attempt context-bound task mutation test"
    static let openAppWhenRun = false

    @Parameter(title: "Expected integration context") var expectedIntegrationContext: String

    init() {}

    init(expectedIntegrationContext: String) {
        self.expectedIntegrationContext = expectedIntegrationContext
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let receipt = try await TaskRepository.shared.complete(
            taskID: "task-001",
            expectedIntegrationContext: expectedIntegrationContext
        )
        return .result(value: receipt.response)
    }
}
#endif

struct TaskShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CompleteTaskIntent(),
            phrases: [
                "Complete the milk task in \(.applicationName)",
                "Complete \(\.$task) in \(.applicationName)",
                "Complete a task in \(.applicationName)"
            ],
            shortTitle: "Complete a task",
            systemImageName: "checkmark.circle"
        )
    }
}
