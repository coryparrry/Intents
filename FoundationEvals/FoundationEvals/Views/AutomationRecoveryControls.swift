import SwiftUI
import AppKit
import IntentsAutomationCore

struct AutomationSelectionHistoryControls: View {
    @Bindable var model: AppAutomationStore
    @State private var showRepository = false
    var body: some View {
        Button("Open repository…", systemImage: "arrow.down.doc") { showRepository = true }
            .disabled(model.busy)
            .sheet(isPresented: $showRepository) { AutomationRepositoryImportSheet(model: model) }
        if !model.recentApplications.isEmpty {
            Menu("Recent apps", systemImage: "clock") {
                ForEach(model.recentApplications) { app in
                    Button { model.reopenApplication(app) } label: { Text(app.name + " · " + app.path) }
                }
                Divider()
                Menu("Remove from recent apps") {
                    ForEach(model.recentApplications) { app in
                        Button(app.name + " · " + app.path) { model.forgetApplication(app) }
                    }
                }
            }.disabled(model.busy)
        }
        if let message = model.recentApplicationsError {
            Text(message).font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct AutomationRepositoryImportSheet: View {
    @Bindable var model: AppAutomationStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open a repository").font(.title2)
            Text("Intents fetches a private copy for inspection. Building and running the app have their own approval.")
            TextField("HTTPS repository URL", text: $address).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("automationRepositoryURL")
            Text("For private repositories, choose an existing authorised checkout from your Mac.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Fetch repository") { model.importRepository(address.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 440)
    }
}

struct AutomationRecoveryControls: View {
    @Bindable var model: AppAutomationStore
    @State private var confirmReset = false
    var body: some View {
        if model.hasUnresolvedOwnership || model.recoveryError != nil {
            GroupBox("Previous runs need attention") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.recoveryItems) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.headline)
                            Text(item.detail).font(.callout)
                            Text("Run \(item.record.runID) · \(item.record.target.id)")
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    if let error = model.recoveryError { Text(error).foregroundStyle(.secondary) }
                    HStack {
                        Button("Check again") { Task { await model.refreshRecovery() } }
                            .disabled(model.busy || model.recoveryLoading)
                        Button("Show saved evidence") { NSWorkspace.shared.activateFileViewerSelecting([model.support]) }
                        Button("Reset device ownership…") { confirmReset = true }
                            .accessibilityIdentifier("automationResetDeviceOwnership")
                            .disabled(model.busy || model.recoveryLoading)
                        if model.recoveryLoading { ProgressView().controlSize(.small) }
                    }
                    Text("Saved cases remain available below. Reopening an app inspects it again; it does not repeat a previous action.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .alert("Reset device ownership?", isPresented: $confirmReset) {
                Button("Cancel", role: .cancel) { }
                Button("Reset device ownership", role: .destructive) { Task { await model.clearUnresolvedAttempt() } }
            } message: {
                Text("This shuts down affected simulators and releases stopped runs. Saved results are kept. Review the workflow before running again.")
            }
        }
    }
}
