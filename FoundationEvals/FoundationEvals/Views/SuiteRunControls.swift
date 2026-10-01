import SwiftUI
#if canImport(FoundationEvalsDeveloper)
import FoundationEvalsDeveloper
#endif

struct SuiteRunControls: View {
    @Bindable var store: EvaluationStore
    @Bindable var runners: DeveloperRunnerStore
    let showRunDetails: () -> Void
    @State private var showsDestination = false
    @State private var showsDevices = false
    @State private var error: String?

    private var activeRun: DeveloperRunStatus? {
        runners.executingRunID.flatMap { runners.status(for: $0) }
    }
    private var busy: Bool { store.isRunning || store.isReassessing || store.isProcessingFiles || activeRun != nil }
    private var runner: DeveloperRunnerSnapshot? { runners.selectedRunner }
    private var destinationName: String {
        runner?.identity.displayName ?? (runners.selectedRunnerID == nil ? "This Mac" : "Unavailable device")
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if store.isRunning || activeRun != nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("\(store.completedSamples) / \(max(store.totalSamples, activeRun?.totalSamples ?? 0))")
                        .font(.caption.monospacedDigit())
                    Button("Cancel", role: .cancel) {
                        if let activeRun { runners.cancelRun(activeRun.id) } else { store.cancelRun() }
                    }
                    .disabled(activeRun?.phase == .cancelled)
                }
            } else if store.hasUnsavedCompletedRun {
                Button("Retry save") { store.retryPendingRunSave() }.buttonStyle(.borderedProminent)
            } else {
                Button("Run suite", systemImage: "play.fill", action: run)
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(runners.runIssue(for: store) != nil || busy)
                    .help(runners.runIssue(for: store) ?? "Run the current suite")
                    .accessibilityIdentifier("Run evaluation")
            }
            Button {
                showsDestination = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: runner?.identity.platform.deviceSymbol ?? "desktopcomputer")
                    Text(destinationName).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .font(.caption)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).disabled(busy)
            .accessibilityLabel("Run destination")
            .popover(isPresented: $showsDestination, arrowEdge: .trailing) { destination }
        }
        .sheet(isPresented: $showsDevices) { DeveloperDevicesView(runners: runners) }
        .alert("Could not start run", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Run destination").font(.headline)
            Picker("Device", selection: $runners.selectedRunnerID) {
                Text("This Mac · built-in evaluator").tag(nil as UUID?)
                if let id = runners.selectedRunnerID, runner == nil {
                    Text("Unavailable device").tag(Optional(id))
                }
                ForEach(runners.runners.filter { $0.state == .connected || $0.id == runners.selectedRunnerID }) { item in
                    Text(item.identity.displayName + (item.state == .connected ? "" : " · disconnected"))
                        .tag(Optional(item.id))
                }
            }
            if let runner {
                Picker("Feature", selection: $runners.selectedFeatureID) {
                    Text("Choose a feature").tag(nil as String?)
                    ForEach(runner.features) { feature in
                        Text(feature.displayName).tag(Optional(feature.id))
                    }
                }
                Text("Calls your app’s feature with each case. Model sessions and tools come from your app.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if runners.selectedRunnerID != nil {
                Text("This device is no longer available. Reconnect it or choose This Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Uses the model and tools configured in this suite.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Run details") { showsDestination = false; showRunDetails() }
            }
            Divider()
            Button("Manage devices & apps", systemImage: "laptopcomputer.and.iphone") {
                showsDestination = false
                showsDevices = true
            }
        }
        .padding(22).frame(width: 365)
        .onChange(of: runners.selectedRunnerID) { _, _ in
            runners.selectedFeatureID = runners.selectedRunner?.features.first?.id
        }
    }

    private func run() {
        do { try runners.startSelectedRun(for: store) }
        catch { self.error = error.localizedDescription }
    }

}

extension DeveloperRunnerStore {
    var selectedRunner: DeveloperRunnerSnapshot? { runners.first { $0.id == selectedRunnerID } }

    @discardableResult
    func startSelectedRun(for store: EvaluationStore) throws -> UUID? {
        guard let runnerID = selectedRunnerID else { store.startRun(); return nil }
        if let issue = runIssue(for: store) { throw EvaluationStoreError.invalidSuite(issue) }
        guard let featureID = selectedFeatureID else { return nil }
        guard store.saveSuite() else {
            throw EvaluationStoreError.invalidSuite(
                store.validationIssue(for: store.draftSuite, includeModelReadiness: false)
                    ?? "Save the current suite before running it on a device."
            )
        }
        return try runSelectedSuite(on: runnerID, featureID: featureID)
    }

    func runIssue(for store: EvaluationStore) -> String? {
        guard selectedRunnerID != nil else { return store.runBlocker }
        guard let runner = selectedRunner, runner.state == .connected else { return "Reconnect the selected device to run this suite." }
        guard runner.features.contains(where: { $0.id == selectedFeatureID }) else { return "Choose an app feature from Run destination." }
        return store.validationIssue(for: store.draftSuite, includeModelReadiness: false)
    }
}

struct DeveloperExecutionSummary: View {
    let execution: EvaluationDeveloperExecution

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer.and.iphone").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(execution.runnerName).font(.callout.weight(.semibold))
                Text("\(execution.hardwareModel) · \(execution.operatingSystem)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(execution.featureID) · v\(execution.featureVersion)").font(.caption.weight(.medium))
                Text("\(execution.appBundleIdentifier) · v\(execution.appVersion)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled).padding(.horizontal, 20).padding(.vertical, 12)
        .background(WorkspaceStyle.surface)
        .accessibilityElement(children: .combine)
    }
}
