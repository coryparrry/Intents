import SwiftData
import SwiftUI

@main
struct IntentLabTasksApp: App {
    private let repository = TaskRepository.shared

    init() {
        #if DEBUG && INTENT_LAB_TEST_SUPPORT
        IntentLabFeatureTestSupportRegistry.install(TaskFeatureTestSupport.shared)
        #endif

        #if DEBUG && INTENT_LAB_TEST_SUPPORT
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-intent-lab-reset") {
            let faultOptionIndex = arguments.firstIndex(of: "-intent-lab-fault").map { $0 + 1 }
            let faultMode = faultOptionIndex.flatMap { arguments.indices.contains($0) ? arguments[$0] : nil } ?? "none"
            let contextOptionIndex = arguments.firstIndex(of: "-intent-lab-context").map { $0 + 1 }
            let context = contextOptionIndex.flatMap { arguments.indices.contains($0) ? arguments[$0] : nil } ?? ""
            do {
                try TaskFeatureTestSupport.prepareForLaunch(faultValue: faultMode, context: context)
            } catch {
                fatalError("Unable to prepare the isolated task dataset: \(error.localizedDescription)")
            }
        }
        #endif

        do {
            try repository.seedInitialTasksIfEmpty()
        } catch {
            fatalError("Unable to seed the task list: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            TaskListView()
                .modelContainer(repository.modelContainer)
        }
    }
}

struct TaskListView: View {
    @Query(sort: \TaskRecord.taskID) private var tasks: [TaskRecord]

    var body: some View {
        NavigationStack {
            List {
                ForEach(tasks) { task in
                    HStack(spacing: 12) {
                        Image(systemName: task.isComplete ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(task.isComplete ? .green : .secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(task.title)
                                .font(.headline)
                            Text(task.isComplete ? "Complete" : "Incomplete")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("task-status-\(task.taskID)")
                        }
                        Spacer()
                        if !task.isComplete {
                            Button("Complete") {
                                complete(task)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("complete-\(task.taskID)")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("row-\(task.taskID)")
                }
            }
            .navigationTitle("Tasks")
            .overlay {
                if tasks.isEmpty {
                    ContentUnavailableView("No tasks", systemImage: "checklist")
                }
            }
        }
    }

    private func complete(_ task: TaskRecord) {
        let taskID = task.taskID
        Task { @MainActor in
            _ = try? TaskRepository.shared.complete(taskID: taskID)
        }
    }
}
