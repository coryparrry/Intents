import SwiftUI
import AppKit
import IntentsAutomationCore

/// Capsule previews remain separate from saved runnable cases and native evidence archives.
struct AppAutomationCapsuleView: View {
    @Bindable var model: AppAutomationStore
    @State private var selectedDigest = ""
    @State private var selection: ExportSelection?
    @State private var pendingExport: ExportSelection?
    @State private var working = false
    @State private var message: String?
    @State private var imported: AutomationImportedCapsule?

    private typealias ExportSelection = AutomationCapsuleExportSelection
    var body: some View {
        GroupBox("Case capsules") {
            VStack(alignment: .leading, spacing: 10) {
                Button("Open case capsule…", action: openCapsule).disabled(working || model.busy)
                if !model.savedCases.isEmpty {
                    Picker("Case to export", selection: $selectedDigest) {
                        Text("Choose a saved case").tag("")
                        ForEach(model.savedCases, id: \.digest) { frozen in
                            Text("\(frozen.plan.execution.operation) · v\(frozen.plan.revision) · \(frozen.digest.prefix(8))").tag(frozen.digest)
                        }
                    }
                    Button("Review capsule export…") {
                        guard let frozen = model.savedCases.first(where: { $0.digest == selectedDigest }) else { return }
                        working = true
                        Task {
                            defer { working = false }
                            do {
                                let (value, attempts, exposure) = try await model.capsuleExportSelection(frozen)
                                selection = .init(frozen: value, attempts: attempts, exposure: exposure)
                            } catch { message = error.localizedDescription }
                        }
                    }.disabled(working || model.busy || selectedDigest.isEmpty)
                }
                Text("Capsules contain reviewed case data and recorded results. Screenshots and raw artifacts are omitted. Secret-tainted attempts cannot be previewed or exported.")
                    .font(.caption).foregroundStyle(.secondary)
                if let imported {
                    Text("Historical capsule · not reverified").font(.headline)
                    Text("\(imported.frozen.plan.app.bundleID) · \(imported.frozen.plan.execution.operation)")
                    Text("Case \(imported.frozen.digest)").font(.caption).textSelection(.enabled)
                    Text("\(imported.historicalAttempts.count) recorded attempts. Open a current app and review a new run to verify its behavior.")
                    ForEach(imported.historicalAttempts, id: \.attemptID) { attempt in
                        Text("\(attempt.attemptID): recorded \(attempt.result.summary.rawValue)")
                            .font(.caption).textSelection(.enabled)
                    }
                    Button("Close capsule preview") { self.imported = nil }
                }
                if let message { Text(message).font(.callout).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
        .sheet(item: $selection, onDismiss: {
            if let value = pendingExport { pendingExport = nil; saveCapsule(value) }
        }) { value in
            VStack(alignment: .leading, spacing: 12) {
                Text("Review case capsule").font(.title2)
                Text("\(value.frozen.plan.app.bundleID) · case \(value.frozen.plan.id) · version \(value.frozen.plan.revision)")
                Text(value.frozen.digest).font(.caption).textSelection(.enabled)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(reviewedJSON(value.frozen))
                            .font(.caption.monospaced()).textSelection(.enabled)
                        ForEach(value.attempts, id: \.attemptID) { attempt in
                            Text(reviewedJSON(attempt))
                                .font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
                Toggle("I reviewed this case and these \(value.attempts.count) attempts as synthetic data and metadata suitable for export", isOn: Binding(
                    get: { selection?.id == value.id && selection?.reviewed == true },
                    set: { if selection?.id == value.id { selection?.reviewed = $0 } }))
                HStack {
                    Button("Cancel") { selection = nil }
                    Spacer()
                    Button("Save capsule…") {
                        guard let reviewed = selection, reviewed.id == value.id, model.canSaveCapsuleExport(reviewed) else { return }
                        pendingExport = reviewed; selection = nil
                    }.disabled((selection.map { !model.canSaveCapsuleExport($0) } ?? true) || working)
                }
            }.padding(20).frame(width: 680, height: 520)
        }
    }

    private func reviewedJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "Case data could not be displayed"
    }
    private func openCapsule() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Open capsule"
        panel.message = "Choose a .intentscase file or directory to view its recorded history."
        present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            working = true
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() }; working = false }
                do {
                    let value = try await Task.detached { try AutomationCaseCapsule.read(url) }.value
                    imported = value; message = nil
                } catch { message = "Could not open capsule: " + error.localizedDescription }
            }
        }
    }
    private func saveCapsule(_ value: ExportSelection) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = value.frozen.plan.id + ".intentscase"
        panel.prompt = "Save capsule"
        panel.message = "Choose a new file. Existing files cannot be replaced."
        present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            working = true
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() }; working = false }
                do {
                    try await model.exportCapsule(value, to: url)
                    message = "Capsule saved: " + url.lastPathComponent
                } catch { message = "Could not save capsule: " + error.localizedDescription }
            }
        }
    }
    private func present(_ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApplication.shared.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}
