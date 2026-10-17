import AppIntents
import SwiftUI

@main
struct AutomationFixtureApp: App {
    init() {
        AutomationFixtureShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene { WindowGroup { TaskListView() } }
}
struct TaskListView: View {
    @State private var repository = TaskRepository.shared
    @State private var title = ""
    @State private var owner = "Personal"
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            Form {
                Section("Control") {
                    Picker("Behavior", selection: Binding(get: { repository.document.control }, set: { repository.chooseControl($0) })) {
                        ForEach(TaskControl.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("fixture.control")
                    Button("Reset fixture", role: .destructive) { repository.reset() }.accessibilityIdentifier("fixture.reset")
                }
                Section("New task") {
                    TextField("Task title", text: $title).accessibilityIdentifier("task.title")
                    Picker("Account", selection: $owner) {
                        Text("Personal").tag("Personal"); Text("Work").tag("Work")
                    }.pickerStyle(.segmented).accessibilityIdentifier("task.owner")
                    Button("Add task") { repository.create(title: title, owner: owner) }
                        .accessibilityIdentifier("task.add").disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("Tasks") {
                    ForEach(repository.document.records) { record in
                        let label = "\(record.owner) · \(record.title) · \(record.completed ? "Complete" : "Open")"
                        HStack {
                            Text(label).accessibilityLabel(label).accessibilityIdentifier("task.record." + record.id)
                            Spacer()
                            Button("Complete") { repository.completeFromUI(id: record.id) }
                                .accessibilityIdentifier("task.complete").disabled(record.completed)
                        }
                    }
                }
                if let error = repository.error { Section { Text(error).foregroundStyle(.red) } }
            }.navigationTitle("Automation Fixture")
        }
        .task { repository.reload() }
        .onChange(of: scenePhase) { if scenePhase == .active { repository.reload() } }
    }
}
