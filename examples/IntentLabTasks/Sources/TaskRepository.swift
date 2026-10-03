import Foundation
import IntentLabContracts
import SwiftData

enum TaskRepositoryError: LocalizedError {
    case missingTask(String)
    case invalidTestFault(String)
    case missingTestContext
    case missingIntegrationEntityContext
    case staleIntegrationContext(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .missingTask(let identifier): "No task exists with identifier \(identifier)."
        case .invalidTestFault(let value): "Unknown integration-test fault: \(value)."
        case .missingTestContext: "The isolated task integration requires an invocation context."
        case .missingIntegrationEntityContext: "The task entity is not bound to the active integration context."
        case .staleIntegrationContext(let expected, let actual):
            "The task entity belongs to integration context \(expected), not the active context \(actual)."
        }
    }
}

struct TaskCompletionReceipt: Sendable {
    let taskID: String
    let title: String
    let response: String
}

#if INTENT_LAB_TESTING || INTENT_LAB_TEST_SUPPORT
enum TaskTestFault: String, CaseIterable {
    case none
    case suppressPersistence
    case mutateUnrelatedTask
}
#endif

@MainActor
final class TaskRepository {
    static let shared: TaskRepository = {
        do {
            return try TaskRepository()
        } catch {
            fatalError("Unable to open the Intent Lab Tasks database: \(error.localizedDescription)")
        }
    }()

    let modelContainer: ModelContainer
    private let modelContext: ModelContext
    private let databaseURL: URL

    private init() throws {
        let supportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let databaseDirectory = supportDirectory.appendingPathComponent("IntentLabTasks", isDirectory: true)
        try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        let storeURL = databaseDirectory.appendingPathComponent("Tasks.sqlite")
        let schema = Schema([TaskRecord.self])
        let configuration = ModelConfiguration(
            "IntentLabTasks",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )

        databaseURL = storeURL
        modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        modelContext = ModelContext(modelContainer)
        try seedInitialTasksIfEmpty()
    }

    func seedInitialTasksIfEmpty() throws {
        guard try modelContext.fetchCount(FetchDescriptor<TaskRecord>()) == 0 else { return }
        insertInitialTasks()
        try modelContext.save()
    }

    func tasks() throws -> [TaskSnapshot] {
        try modelContext.fetch(FetchDescriptor<TaskRecord>(sortBy: [SortDescriptor(\.taskID)]))
            .map(Self.snapshot)
    }

    func tasks(identifiers: [String]) throws -> [TaskSnapshot] {
        let requested = Set(identifiers)
        return try tasks().filter { requested.contains($0.id) }
    }

    func tasks(matching query: String) throws -> [TaskSnapshot] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return try tasks() }
        return try tasks().filter { $0.title.localizedCaseInsensitiveContains(normalizedQuery) }
    }

    /// Opens a new SwiftData container for every observation so a query reads saved store state
    /// independently from the context that performed the measured action.
    func persistedTasks(identifiers: [String]) throws -> [TaskSnapshot] {
        let schema = Schema([TaskRecord.self])
        let configuration = ModelConfiguration(
            "IntentLabTasks",
            schema: schema,
            url: databaseURL,
            cloudKitDatabase: .none
        )
        let readbackContainer = try ModelContainer(for: schema, configurations: [configuration])
        let readbackContext = ModelContext(readbackContainer)
        let requested = Set(identifiers)
        return try readbackContext.fetch(FetchDescriptor<TaskRecord>(sortBy: [SortDescriptor(\.taskID)]))
            .filter { requested.contains($0.taskID) }
            .map(Self.snapshot)
    }

#if INTENT_LAB_TESTING || INTENT_LAB_TEST_SUPPORT
    var integrationContextForEntity: String { Self.currentInvocationContext }
#else
    var integrationContextForEntity: String { "" }
#endif

    /// Completes a task from the in-app UI. App Intents must use the context-bound overload below.
    func complete(taskID: String) throws -> TaskCompletionReceipt {
        try completeTask(taskID: taskID)
    }

    /// Completes a task selected through App Intents. Test builds require a nonempty entity context
    /// so a shortcut with a serialized, unbound entity cannot act on a later prepared dataset.
    func complete(taskID: String, expectedIntegrationContext: String) throws -> TaskCompletionReceipt {
#if INTENT_LAB_TESTING || INTENT_LAB_TEST_SUPPORT
        let activeContext = Self.currentInvocationContext
        guard !activeContext.isEmpty else { throw TaskRepositoryError.missingTestContext }
        guard !expectedIntegrationContext.isEmpty else {
            throw TaskRepositoryError.missingIntegrationEntityContext
        }
        if expectedIntegrationContext != activeContext {
            throw TaskRepositoryError.staleIntegrationContext(
                expected: expectedIntegrationContext,
                actual: activeContext
            )
        }
#endif
        return try completeTask(taskID: taskID)
    }

    private func completeTask(taskID: String) throws -> TaskCompletionReceipt {
        guard let task = try find(taskID: taskID) else { throw TaskRepositoryError.missingTask(taskID) }
        let title = task.title

        #if INTENT_LAB_TESTING || INTENT_LAB_TEST_SUPPORT
        switch Self.currentTestFault {
        case .suppressPersistence:
            // Deliberately return the ordinary completion receipt without saving any change.
            return TaskCompletionReceipt(taskID: taskID, title: title, response: "Completed \(title).")
        case .mutateUnrelatedTask:
            task.isComplete = true
            task.updatedAt = .now
            if let unrelated = try find(taskID: "task-002") {
                unrelated.isComplete.toggle()
                unrelated.updatedAt = .now
            }
        case .none:
            task.isComplete = true
            task.updatedAt = .now
        }
        #else
        task.isComplete = true
        task.updatedAt = .now
        #endif

        task.invocationContext = Self.currentInvocationContext
        task.actionReceiptID = UUID().uuidString

        try modelContext.save()
        return TaskCompletionReceipt(taskID: taskID, title: title, response: "Completed \(title).")
    }

    #if INTENT_LAB_TESTING || INTENT_LAB_TEST_SUPPORT
    func prepareIntegrationDataset(faultValue: String, context: String) throws {
        guard let fault = TaskTestFault(rawValue: faultValue) else {
            throw TaskRepositoryError.invalidTestFault(faultValue)
        }
        guard !context.isEmpty else { throw TaskRepositoryError.missingTestContext }

        for task in try modelContext.fetch(FetchDescriptor<TaskRecord>()) {
            modelContext.delete(task)
        }
        insertInitialTasks()
        UserDefaults.standard.set(fault.rawValue, forKey: Self.testFaultDefaultsKey)
        UserDefaults.standard.set(context, forKey: Self.testInvocationContextKey)
        TaskActionReceipts.reset()
        try modelContext.save()
    }

    private static let testFaultDefaultsKey = "intent-lab-tasks.test-fault"
    private static let testInvocationContextKey = "intent-lab-tasks.invocation-context"

    private static var currentTestFault: TaskTestFault {
        TaskTestFault(rawValue: UserDefaults.standard.string(forKey: testFaultDefaultsKey) ?? "none") ?? .none
    }

    private static var currentInvocationContext: String {
        UserDefaults.standard.string(forKey: testInvocationContextKey) ?? ""
    }
    #else
    private static var currentInvocationContext: String { "" }
    #endif

    private func find(taskID: String) throws -> TaskRecord? {
        let requestedID = taskID
        var descriptor = FetchDescriptor<TaskRecord>(predicate: #Predicate { $0.taskID == requestedID })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func insertInitialTasks() {
        for task in ExampleTasks.initial {
            modelContext.insert(TaskRecord(taskID: task.id, title: task.title, isComplete: false))
        }
    }

    private static func snapshot(_ record: TaskRecord) -> TaskSnapshot {
        TaskSnapshot(
            id: record.taskID,
            title: record.title,
            isComplete: record.isComplete,
            updatedAt: record.updatedAt,
            invocationContext: record.invocationContext,
            actionReceiptID: record.actionReceiptID
        )
    }
}

/// The production operation behind both the real App Intent and the local-feature
/// test route. The receipt starts here, before the repository call.
@MainActor
final class TaskCompletionService {
    static let shared = TaskCompletionService()

    private init() {}

    func completeFromInvocation(
        taskID: String,
        expectedIntegrationContext: String,
        context: String,
        lane: IntentLabLane,
        kind: IntentLabActionKind,
        operationID: String
    ) throws -> TaskCompletionReceipt {
        let resolvedParameters: [String: IntentLabValue] = kind == .productionIntent
            ? ["task": .entity(.init(typeIdentifier: "TaskEntity", identifier: taskID))]
            : ["taskID": .string(taskID)]
#if DEBUG
        let action = TaskActionReceipts.begin(
            context: context,
            lane: lane,
            kind: kind,
            operationID: operationID,
            resolvedParameters: resolvedParameters
        )
#else
        _ = (context, lane, kind, operationID, resolvedParameters)
#endif
        do {
            let result = try TaskRepository.shared.complete(
                taskID: taskID,
                expectedIntegrationContext: expectedIntegrationContext
            )
#if DEBUG
            TaskActionReceipts.finish(action)
#endif
            return result
        } catch {
#if DEBUG
            TaskActionReceipts.finish(action, error: error)
#endif
            throw error
        }
    }
}

#if DEBUG
struct TaskActionExecution {
    fileprivate let executionID: UUID
    fileprivate let appSessionID: UUID
    fileprivate let attemptContext: String
    fileprivate let lane: IntentLabLane
    fileprivate let attempt: Int
    fileprivate let kind: IntentLabActionKind
    fileprivate let operationID: String
    fileprivate let resolvedParameters: [String: IntentLabValue]
    fileprivate let isTopLevel: Bool
    fileprivate let sequence: Int
    fileprivate let startedAt: Date
}

@MainActor
enum TaskActionReceipts {
    private static let key = "intent-lab-tasks.action-receipts"
    private static let overflowKey = "intent-lab-tasks.action-receipts-overflowed"
    private static let limit = 16
    private static let byteLimit = 65_536
    private static let errorCharacterLimit = 512
    private static let appSessionID = UUID()
    private static var sequence = 0

    static func begin(
        context: String,
        lane: IntentLabLane,
        attempt: Int = 1,
        kind: IntentLabActionKind,
        operationID: String,
        resolvedParameters: [String: IntentLabValue],
        isTopLevel: Bool = true
    ) -> TaskActionExecution {
        sequence += 1
        return TaskActionExecution(
            executionID: UUID(),
            appSessionID: appSessionID,
            attemptContext: context,
            lane: lane,
            attempt: attempt,
            kind: kind,
            operationID: operationID,
            resolvedParameters: resolvedParameters,
            isTopLevel: isTopLevel,
            sequence: sequence,
            startedAt: Date()
        )
    }

    static func finish(_ action: TaskActionExecution, error: Error? = nil) {
        let message = error.map { error -> String in
            let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            return String((description.isEmpty ? "The task operation failed." : description).prefix(errorCharacterLimit))
        }
        let receipt = IntentLabActionReceipt(
            executionID: action.executionID,
            appSessionID: action.appSessionID,
            attemptContext: action.attemptContext,
            lane: action.lane,
            attempt: action.attempt,
            kind: action.kind,
            operationID: action.operationID,
            resolvedParameters: action.resolvedParameters,
            terminalStatus: error == nil ? .succeeded : .failed,
            operationError: message,
            sequence: action.sequence,
            startedAt: action.startedAt,
            completedAt: Date(),
            observationTransport: "entityQuery",
            isTopLevel: action.isTopLevel
        )
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: overflowKey),
              var receipts = decode(defaults.data(forKey: key)) else {
            defaults.set(true, forKey: overflowKey)
            return
        }
        receipts.append(receipt)
        guard receipts.count <= limit else {
            defaults.set(true, forKey: overflowKey)
            return
        }
        let data = encode(receipts)
        guard data.count <= byteLimit else {
            defaults.set(true, forKey: overflowKey)
            return
        }
        defaults.set(data, forKey: key)
    }

    static var json: String {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: overflowKey),
              let data = defaults.data(forKey: key),
              let receipts = decode(data),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        guard receipts.count <= limit else { return "[]" }
        return text
    }

    static func reset() {
        let defaults = UserDefaults.standard
        defaults.set(encode([]), forKey: key)
        defaults.set(false, forKey: overflowKey)
        sequence = 0
    }

    private static func decode(_ data: Data?) -> [IntentLabActionReceipt]? {
        guard let data else { return [] }
        guard data.count <= byteLimit,
              let receipts = try? JSONDecoder.intentLab.decode([IntentLabActionReceipt].self, from: data),
              receipts.count <= limit else { return nil }
        return receipts
    }

    private static func encode(_ receipts: [IntentLabActionReceipt]) -> Data {
        (try? JSONEncoder.intentLab.encode(receipts)) ?? Data("[]".utf8)
    }
}
#endif
