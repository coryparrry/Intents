import SwiftUI
import AppKit
import IntentsAutomationCore

struct AutomationRecoveryControls: View {
    @Bindable var model: AppAutomationStore
    @State private var confirmReset = false
    var body: some View {
        if !model.recoveryItems.isEmpty || model.recoveryError != nil || model.retainedUnresolvedNormalReport != nil {
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
