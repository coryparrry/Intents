import SwiftUI

/// Both app-testing routes remain discoverable when the optional lab is unavailable.
struct AppTestingWorkspaceView: View {
    @Bindable var store: EvaluationStore
    let automationStore: AppAutomationStore
    let coordinator: ScenarioCoordinator
    let intentLabEnabled: Bool

    private var route: Binding<SidebarSelection> {
        Binding(get: { store.selection }, set: { store.selection = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("App testing", selection: route) {
                    Text("App automation & Siri").tag(SidebarSelection.appAutomation)
                    Text("Intent Lab · Beta").tag(SidebarSelection.intentLab)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 480)
                .accessibilityIdentifier("App testing route")
                .help(store.selection == .intentLab
                     ? "Verify App Intent requirements with Apple test connections and saved evidence."
                     : "Prepare an app, inspect its exposed actions, and verify UI or Siri behavior on a supported target.")
                Spacer(minLength: 0)
                Text("Shared workspace")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("App automation uses a shared workspace across projects. Intent Lab can link requirements to model evaluation suites.")
            }
            .padding(.horizontal, 24).padding(.vertical, 8)
            Divider()
            if store.selection == .intentLab {
                if intentLabEnabled {
                    IntentLabView(coordinator: coordinator, store: store, projects: store.projects)
                } else {
                    ContentUnavailableView("Intent Lab unavailable", systemImage: "lock",
                        description: Text(IntentLabFeatureGate.unavailableMessage
                            + " App automation and Siri checks remain available in the other tab."))
                }
            } else {
                AppAutomationView(model: automationStore)
            }
        }
    }
}
