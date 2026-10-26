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
    private var textFeatures: [DeveloperFeatureDescriptor] {
        runner?.features.filter { EvaluationDeveloperFeatureAdapter.validationIssue(for: $0) == nil } ?? []
    }
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
        .accessibilityIdentifier("Run destination")
        .popover(isPresented: $showsDestination, arrowEdge: .bottom) { destination }
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                WorkspaceIcon(symbol: "play.circle.fill", size: 28)
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
                    if let selected = runner.features.first(where: { $0.id == runners.selectedFeatureID }),
                       EvaluationDeveloperFeatureAdapter.validationIssue(for: selected) != nil {
                        Text(selected.displayName + " · incompatible input").tag(Optional(selected.id)).disabled(true)
                    }
                    ForEach(textFeatures) { feature in
                        Text(feature.displayName).tag(Optional(feature.id))
                    }
                }
                Text(!textFeatures.isEmpty
                     ? "Calls your app’s text feature with each case. Model sessions and tools come from your app."
                     : "This app exposes no text features for suites. Register a text feature in the app.")
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
            runners.selectedFeatureID = runners.selectedRunner?.features.first(where: {
                EvaluationDeveloperFeatureAdapter.validationIssue(for: $0) == nil
            })?.id
        }
    }
}

private struct SuiteRunButton: View {
    @Bindable var store: EvaluationStore
    @Bindable var runners: DeveloperRunnerStore
    @Binding var showsRunDetails: Bool
    let reportError: (String) -> Void
    @State private var showsRecoveryConfirmation = false

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
            } else if store.pendingCompletedRunsLoadError != nil {
                Button("Preserve unreadable evidence…", systemImage: "archivebox") {
                    showsRecoveryConfirmation = true
                }
                .confirmationDialog("Preserve unreadable recovery data?", isPresented: $showsRecoveryConfirmation) {
                    Button("Preserve and allow new runs") {
                        do { try store.preserveUnreadablePendingRuns() }
                        catch { reportError(error.localizedDescription) }
                    }
                } message: {
                    Text("The original file will be kept for inspection. Its contents cannot count as release evidence. You can then run a new check.")
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

    /// Starts the selected local or device run and forwards a localized startup error to the host.
    private func run() {
        do { try runners.startSelectedRun(for: store) }
        catch { reportError(error.localizedDescription) }
    }
}

extension DeveloperRunnerStore {
    var selectedRunner: DeveloperRunnerSnapshot? { runners.first { $0.id == selectedRunnerID } }

    /// Reports whether evaluation, reassessment, file processing, or a developer-device run currently owns execution resources.
    func isBusy(for store: EvaluationStore) -> Bool {
        store.isRunning || store.isReassessing || store.isProcessingFiles || executingRunID != nil
    }

    /// Allows a new run only when resources are idle, completed results are saved, and destination validation passes.
    func canStartRun(for store: EvaluationStore) -> Bool {
        !isBusy(for: store) && !store.hasUnsavedCompletedRun && runIssue(for: store) == nil
    }

    /// Reports whether the current device run still accepts cancellation, otherwise using the local run state.
    func canCancelRun(for store: EvaluationStore) -> Bool {
        if let runID = executingRunID {
            return status(for: runID)?.phase != .cancelled
        }
        return store.isRunning
    }

    /// Routes cancellation to the owning developer-device run when present, or to the local evaluation store.
    func cancelCurrentRun(for store: EvaluationStore) {
        if let runID = executingRunID {
            cancelRun(runID)
        } else {
            store.cancelRun()
        }
    }

    /// Starts a local run when no device is selected, otherwise validates the device feature and saves the suite before device execution.
    /// Throws for resource conflicts or invalid device input; returns the device run ID, or nil for the local path.
    @discardableResult
    func startSelectedRun(for store: EvaluationStore) throws -> UUID? {
        guard !isBusy(for: store) else {
            throw EvaluationStoreError.resourceConflict("Another evaluation operation is already running.")
        }
        guard let runnerID = selectedRunnerID else { store.startRun(); return nil }
        if let issue = runIssue(for: store) { throw EvaluationStoreError.invalidSuite(issue) }
        guard let featureID = selectedFeatureID else { return nil }
        guard store.saveSuite(forDeveloperFeature: true) else {
            throw EvaluationStoreError.invalidSuite(
                store.developerFeatureValidationIssue(for: store.draftSuite)
                    ?? "Save the current suite before running it on a device."
            )
        }
        return try runSelectedSuite(on: runnerID, featureID: featureID)
    }

    /// Returns the local run blocker or the first connection, feature, or suite issue preventing the selected device run.
    func runIssue(for store: EvaluationStore) -> String? {
        guard selectedRunnerID != nil else { return store.runBlocker }
        guard let runner = selectedRunner, runner.state == .connected else { return "Reconnect the selected device to run this suite." }
        guard let feature = runner.features.first(where: { $0.id == selectedFeatureID }) else { return "Choose an app feature from Run destination." }
        if let issue = EvaluationDeveloperFeatureAdapter.validationIssue(for: feature) { return issue }
        return store.developerFeatureValidationIssue(for: store.draftSuite)
    }
}

struct DeveloperExecutionSummary: View {
    let execution: EvaluationDeveloperExecution

    var body: some View {
        HStack(spacing: 12) {
            WorkspaceIcon(symbol: "laptopcomputer.and.iphone", size: 28)
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
