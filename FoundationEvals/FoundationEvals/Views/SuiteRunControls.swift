import SwiftUI
#if canImport(FoundationEvalsDeveloper)
import FoundationEvalsDeveloper
#endif

/// Run destination and run controls, shown at the trailing edge of the suite toolbar.
struct SuiteRunToolbar: ToolbarContent {
    @Bindable var store: EvaluationStore
    @Bindable var runners: DeveloperRunnerStore
    @Binding var showsRunDetails: Bool
    @Binding var showsDevices: Bool
    @Binding var error: String?

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            WorkspaceResetControl(store: store)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            SuiteRunDestinationButton(
                store: store,
                runners: runners,
                showRunDetails: { showsRunDetails = true },
                manageDevices: { showsDevices = true }
            )
        }
        ToolbarItem(placement: .primaryAction) {
            SuiteRunButton(store: store, runners: runners, showsRunDetails: $showsRunDetails) { error = $0 }
        }
    }
}

private struct SuiteRunDestinationButton: View {
    let store: EvaluationStore
    @Bindable var runners: DeveloperRunnerStore
    let showRunDetails: () -> Void
    let manageDevices: () -> Void
    @State private var showsDestination = false

    private var runner: DeveloperRunnerSnapshot? { runners.selectedRunner }
    private var destinationName: String {
        runner?.identity.displayName ?? (runners.selectedRunnerID == nil ? "This Mac" : "Unavailable device")
    }

    var body: some View {
        Button {
            showsDestination = true
        } label: {
            Label(destinationName, systemImage: runner?.identity.platform.deviceSymbol ?? "desktopcomputer")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .frame(maxWidth: 170)
        }
        .disabled(runners.isBusy(for: store))
        .help("Choose where this suite runs")
        .accessibilityLabel("Run destination")
        .accessibilityValue(destinationName)
        .popover(isPresented: $showsDestination, arrowEdge: .bottom) { destination }
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                WorkspaceIconTile(symbol: "play.circle.fill", tint: .accentColor, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Run destination").font(.headline)
                    Text("Where each case is sent when you run the suite.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
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
            }
            Divider()
            HStack {
                Button("Manage Devices & Apps…", systemImage: "laptopcomputer.and.iphone") {
                    showsDestination = false
                    manageDevices()
                }
                Spacer()
                if runners.selectedRunnerID == nil {
                    Button("Run Details") { showsDestination = false; showRunDetails() }
                }
            }
            .controlSize(.small)
        }
        .padding(20).frame(width: 380)
        .onChange(of: runners.selectedRunnerID) { _, _ in
            runners.selectedFeatureID = runners.selectedRunner?.features.first?.id
        }
    }
}

private struct SuiteRunButton: View {
    @Bindable var store: EvaluationStore
    @Bindable var runners: DeveloperRunnerStore
    @Binding var showsRunDetails: Bool
    let reportError: (String) -> Void

    private var activeRun: DeveloperRunStatus? {
        runners.executingRunID.flatMap { runners.status(for: $0) }
    }

    var body: some View {
        Group {
            if store.isRunning || runners.executingRunID != nil {
                HStack(spacing: 2) {
                    RunToolbarProgress(
                        completed: store.completedSamples,
                        total: max(store.totalSamples, activeRun?.totalSamples ?? 0)
                    )
                    Button("Cancel", systemImage: "stop.fill", role: .cancel) {
                        runners.cancelCurrentRun(for: store)
                    }
                    .labelStyle(.iconOnly)
                    .help("Cancel the current run")
                    .disabled(!runners.canCancelRun(for: store))
                }
            } else if store.hasUnsavedCompletedRun {
                Button("Retry Save", systemImage: "arrow.clockwise") { store.retryPendingRunSave() }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderedProminent)
                    .tint(WorkspaceStyle.warning)
            } else {
                Button(action: run) {
                    Label("Run", systemImage: "play.fill").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!runners.canStartRun(for: store))
                .help(runners.runIssue(for: store) ?? "Run the current suite (⌘↩)")
                .accessibilityLabel("Run suite")
                .accessibilityIdentifier("Run evaluation")
            }
        }
        .popover(isPresented: $showsRunDetails, arrowEdge: .bottom) {
            RunReadinessPanel(store: store).frame(width: 520)
        }
    }

    private func run() {
        do { try runners.startSelectedRun(for: store) }
        catch { reportError(error.localizedDescription) }
    }
}

/// Live progress for the run in flight, pinned above the page content.
struct SuiteRunActivityBanner: View {
    let store: EvaluationStore
    let runners: DeveloperRunnerStore

    private var total: Int {
        let active = runners.executingRunID.flatMap { runners.status(for: $0) }
        return max(store.totalSamples, active?.totalSamples ?? 0)
    }

    var body: some View {
        HStack(spacing: 14) {
            WorkspaceIconTile(symbol: "waveform", tint: .accentColor, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Collecting responses").font(.headline)
                Text("\(store.completedSamples) of \(total) responses")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 20)
            ProgressView(value: Double(store.completedSamples), total: Double(max(total, 1)))
                .progressViewStyle(.linear)
                .frame(maxWidth: 260)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .workspaceSurface()
        .accessibilityElement(children: .contain)
    }
}

extension DeveloperRunnerStore {
    var selectedRunner: DeveloperRunnerSnapshot? { runners.first { $0.id == selectedRunnerID } }

    func isBusy(for store: EvaluationStore) -> Bool {
        store.isRunning || store.isReassessing || store.isProcessingFiles || executingRunID != nil
    }

    func canStartRun(for store: EvaluationStore) -> Bool {
        !isBusy(for: store) && !store.hasUnsavedCompletedRun && runIssue(for: store) == nil
    }

    func canCancelRun(for store: EvaluationStore) -> Bool {
        if let runID = executingRunID {
            return status(for: runID)?.phase != .cancelled
        }
        return store.isRunning
    }

    func cancelCurrentRun(for store: EvaluationStore) {
        if let runID = executingRunID {
            cancelRun(runID)
        } else {
            store.cancelRun()
        }
    }

    @discardableResult
    func startSelectedRun(for store: EvaluationStore) throws -> UUID? {
        guard !isBusy(for: store) else {
            throw EvaluationStoreError.resourceConflict("Another evaluation operation is already running.")
        }
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
            WorkspaceIconTile(symbol: "laptopcomputer.and.iphone", tint: .indigo, size: 28)
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
        .textSelection(.enabled).padding(.horizontal, 18).padding(.vertical, 12)
        .workspaceSurface()
        .accessibilityElement(children: .combine)
    }
}
