import AppIntents
import Foundation

struct TaskEntity: AppEntity, Identifiable {
    var id: String
    @Property(title: "Task title") var title: String
    @Property(title: "Completed") var isComplete: Bool
    @Property(title: "Last updated") var updatedAt: Date
    @Property(title: "Invocation context") var invocationContext: String
    @Property(title: "Action receipt") var actionReceiptID: String
#if DEBUG
    @Property(title: "Action receipts") var actionReceipts: String
#endif
    @Property(title: "Integration context") var integrationContext: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Task"
    static let defaultQuery = TaskEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(isComplete ? "Complete" : "Incomplete")"
        )
    }

    init(snapshot: TaskSnapshot, integrationContext: String = "", actionReceipts: String = "[]") {
        id = snapshot.id
        title = snapshot.title
        isComplete = snapshot.isComplete
        updatedAt = snapshot.updatedAt
        invocationContext = snapshot.invocationContext
        actionReceiptID = snapshot.actionReceiptID
#if DEBUG
        self.actionReceipts = actionReceipts
#else
        _ = actionReceipts
#endif
        self.integrationContext = integrationContext
    }

    init(id: String, title: String, isComplete: Bool = false, updatedAt: Date = .distantPast) {
        self.id = id
        self.title = title
        self.isComplete = isComplete
        self.updatedAt = updatedAt
        invocationContext = ""
        actionReceiptID = ""
#if DEBUG
        actionReceipts = "[]"
#endif
        integrationContext = ""
    }
}

struct TaskEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [TaskEntity] {
        let integrationContext = await TaskRepository.shared.integrationContextForEntity
#if DEBUG
        let actionReceipts = await TaskActionReceipts.json
#else
        let actionReceipts = "[]"
#endif
        return try await TaskRepository.shared.persistedTasks(identifiers: identifiers).map {
            TaskEntity(snapshot: $0, integrationContext: integrationContext, actionReceipts: actionReceipts)
        }
    }

    func entities(matching string: String) async throws -> [TaskEntity] {
        let matchingIDs = try await TaskRepository.shared.tasks(matching: string).map(\.id)
        let integrationContext = await TaskRepository.shared.integrationContextForEntity
#if DEBUG
        let actionReceipts = await TaskActionReceipts.json
#else
        let actionReceipts = "[]"
#endif
        return try await TaskRepository.shared.persistedTasks(identifiers: matchingIDs).map {
            TaskEntity(snapshot: $0, integrationContext: integrationContext, actionReceipts: actionReceipts)
        }
    }

    func suggestedEntities() async throws -> [TaskEntity] {
        let allIDs = try await TaskRepository.shared.tasks().map(\.id)
        let integrationContext = await TaskRepository.shared.integrationContextForEntity
#if DEBUG
        let actionReceipts = await TaskActionReceipts.json
#else
        let actionReceipts = "[]"
#endif
        return try await TaskRepository.shared.persistedTasks(identifiers: allIDs).map {
            TaskEntity(snapshot: $0, integrationContext: integrationContext, actionReceipts: actionReceipts)
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
        let receipt = try await TaskCompletionService.shared.completeFromInvocation(
            taskID: task.id,
            expectedIntegrationContext: task.integrationContext,
            context: task.integrationContext,
            lane: .intentIntegration,
            kind: .productionIntent,
            operationID: "CompleteTaskIntent"
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
        let receipt = try await TaskCompletionService.shared.completeFromInvocation(
            taskID: "task-001",
            expectedIntegrationContext: expectedIntegrationContext,
            context: expectedIntegrationContext,
            lane: .intentIntegration,
            kind: .testSupport,
            operationID: "AttemptContextTaskMutationTestIntent"
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
