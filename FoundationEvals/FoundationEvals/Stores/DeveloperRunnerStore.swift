import Foundation
#if canImport(FoundationEvalsDeveloper)
import FoundationEvalsDeveloper
#endif
import Observation

@MainActor
@Observable
final class DeveloperRunnerStore {
    let client: DeveloperRunnerClient
    private(set) var activeRuns: [UUID: DeveloperRunStatus] = [:]
    private(set) var executingRunID: UUID?
    var selectedFeatureID: String?

    @ObservationIgnored private let evaluationStore: EvaluationStore
    @ObservationIgnored private let runnerSnapshots: (@MainActor () -> [DeveloperRunnerSnapshot])?
    @ObservationIgnored private let runOverride: (@MainActor (UUID, String) async throws -> EvaluationRun)?
    @ObservationIgnored private var isClosing = false
    @ObservationIgnored private var runTasks: [UUID: Task<Void, Never>] = [:]

    /// Creates a main-actor runner coordinator using workspace-local identity and trust storage.
    /// Optional transport snapshots and execution support isolated fixtures; production uses the connected client and persisted feature-run path.
    init(
        evaluationStore: EvaluationStore,
        desktopID: UUID? = nil,
        client: DeveloperRunnerClient? = nil,
        runnerSnapshots: (@MainActor () -> [DeveloperRunnerSnapshot])? = nil,
        runOverride: (@MainActor (UUID, String) async throws -> EvaluationRun)? = nil
    ) {
        self.evaluationStore = evaluationStore
        self.runnerSnapshots = runnerSnapshots
        self.runOverride = runOverride
        let directory = evaluationStore.overviewStorageDirectory
            .appending(path: "DeveloperRunners", directoryHint: .isDirectory)
        let resolvedDesktopID = desktopID ?? Self.loadOrCreateDesktopID(
            at: directory.appending(path: "desktop-id.txt")
        )
        self.client = client ?? DeveloperRunnerClient(
            desktopID: resolvedDesktopID,
            trustStoreURL: directory.appending(path: "trusted-runners.json")
        )
    }

    var runners: [DeveloperRunnerSnapshot] { runnerSnapshots?() ?? client.runners }

    var selectedRunnerID: UUID? {
        get { client.selectedRunnerID }
        set { client.selectedRunnerID = newValue }
    }

    var pairingChallenges: [UUID: DeveloperPairingChallenge] {
        client.pendingPairingChallenges
    }

    var isBrowsing: Bool { client.isBrowsing }
    var lastError: String? { client.lastError }

    /// Starts runner discovery unless the store has closed admission.
    func start() {
        guard !isClosing else { return }
        client.startBrowsing()
    }

    /// Requests cancellation of owned runs and shuts down the runner client.
    /// Executing ownership remains until tracked work finishes; closeAndWait also joins that work.
    func stop() {
        for task in runTasks.values {
            task.cancel()
        }
        if runTasks.isEmpty {
            executingRunID = nil
        }
        client.shutdown()
    }

    /// Closes admission and waits for owned work to retain its terminal evidence.
    func closeAndWait() async {
        isClosing = true
        let runs = Array(runTasks.values)
        stop()
        for task in runs { await task.value }
    }

    /// Connects to a discovered endpoint. Pairing remains incomplete until the
    /// user enters the code displayed by the runner app in `trustRunner`.
    func beginPairing(with runnerID: UUID) throws {
        guard !isClosing else { throw EvaluationStoreError.resourceConflict("Developer runners are closing.") }
        try client.connect(to: runnerID)
    }

    /// Disconnects the endpoint to abandon its current pairing attempt.
    func cancelPairing(with runnerID: UUID) {
        client.disconnect(runnerID)
    }

    /// Trusts a runner using its displayed pairing code, throwing if closing or client verification/storage fails.
    func trustRunner(_ runnerID: UUID, pairingCode: String) throws {
        guard !isClosing else { throw EvaluationStoreError.resourceConflict("Developer runners are closing.") }
        try client.trustRunner(runnerID, pairingCode: pairingCode)
    }

    /// Disconnects the runner without removing its saved trust.
    func disconnect(_ runnerID: UUID) {
        client.disconnect(runnerID)
    }

    /// Removes saved trust for a runner, propagating client persistence errors.
    func forgetTrust(for runnerID: UUID) throws {
        try client.forgetTrust(for: runnerID)
    }

    /// Starts the selected canonical suite on a connected runner feature and returns its tracking ID.
    /// Rejects concurrent execution or unsupported features; captures the suite revision before dispatch and publishes terminal status.
    /// Records one content-free operation through admission and durable completion, treating assertion failures as completed executions.
    @discardableResult
    func runSelectedSuite(
        on runnerID: UUID,
        featureID: String,
        timeout: Duration = .seconds(120)
    ) throws -> UUID {
        let telemetry = evaluationStore.telemetry
        let span = telemetry?.begin(.appIntentRun)
        do {
            guard !isClosing,
                  executingRunID == nil, !evaluationStore.hasActiveExecution else {
                throw EvaluationStoreError.resourceConflict("Another evaluation is already running.")
            }
            guard let runner = runners.first(where: { $0.id == runnerID && $0.state == .connected }) else {
                throw DeveloperExecutionFailure(code: .disconnected, message: "Connect the runner before starting a run.")
            }
            guard let feature = runner.features.first(where: { $0.id == featureID }) else {
                throw DeveloperExecutionFailure(
                    code: .featureNotFound,
                    message: "The selected feature is not available on this runner."
                )
            }
            try EvaluationDeveloperFeatureAdapter.validate(feature)

            let revision = try evaluationStore.currentSuiteRevision()
            let runID = UUID()
            let total = evaluationStore.suite.cases.count * evaluationStore.suite.repetitions
            activeRuns[runID] = .init(
                id: runID,
                runnerID: runnerID,
                featureID: featureID,
                phase: .preparing,
                completedSamples: 0,
                totalSamples: total
            )
            selectedRunnerID = runnerID
            selectedFeatureID = featureID

            startTrackedExecution(runID: runID) { [self] in
                self.activeRuns[runID]?.phase = .dispatching
                do {
                    let run: EvaluationRun
                    if let runOverride {
                        run = try await runOverride(runID, revision)
                    } else {
                        run = try await self.evaluationStore.runDeveloperFeature(
                            id: runID,
                            expectedRevision: revision,
                            runner: runner,
                            feature: feature,
                            client: self.client,
                            timeout: timeout
                        ) { [weak self] completed, total in
                            await self?.updateProgress(runID: runID, completed: completed, total: total)
                        }
                    }
                    self.projectCompletion(.success(run), for: runID)
                    telemetry?.end(span, failure: Self.telemetryFailure(for: run))
                } catch {
                    self.projectCompletion(.failure(error), for: runID)
                    telemetry?.end(span, failure: Self.telemetryFailure(for: error))
                }
            }
            return runID
        } catch {
            telemetry?.end(span, failure: Self.telemetryFailure(for: error))
            throw error
        }
    }

    /// Waits for retained execution without cancellation, including its terminal status and telemetry publication.
    func waitForRun(_ runID: UUID) async {
        await runTasks[runID]?.value
    }

    /// Maps terminal runner evidence without transmitting any runner identity, response, or error description.
    private static func telemetryFailure(for run: EvaluationRun) -> TelemetryFailure? {
        if run.cancelled { return .cancelled }
        switch run.terminationReason {
        case "cancelled", "developerRunner:cancelled": return .cancelled
        case "developerRunner:deadlineExceeded": return .timeout
        case "developerRunner:disconnected": return .deviceUnavailable
        case "assessmentUnavailable": return .judge
        case .some: return .unexpected
        case nil: break
        }
        if run.results.contains(where: { $0.errorCategory == "featureAdapterFailure" }) { return .generation }
        return TelemetryFailure.evaluationFailure(results: run.effectiveResults, cancelled: false)
    }

    /// Maps structured transport and persistence failures to fixed categories, never their localized messages.
    private static func telemetryFailure(for error: any Error) -> TelemetryFailure {
        guard let failure = error as? DeveloperExecutionFailure else { return .classify(error) }
        switch failure.code {
        case .cancelled: return .cancelled
        case .deadlineExceeded: return .timeout
        case .disconnected: return .deviceUnavailable
        case .untrustedPeer: return .permission
        case .executionFailed: return .generation
        case .featureNotFound, .incompatibleFeatureVersion, .invalidInput, .unsupportedInputContract, .protocolMismatch:
            return .validation
        }
    }

    /// Cancels owned work for the run and immediately publishes cancellation-requested detail in its UI status.
    func cancelRun(_ runID: UUID) {
        runTasks[runID]?.cancel()
        activeRuns[runID]?.phase = .cancelled
        activeRuns[runID]?.detail = "Cancellation requested."
    }

    /// Returns the most recently projected status for a tracked developer run, or nil for an unknown ID.
    func status(for runID: UUID) -> DeveloperRunStatus? {
        activeRuns[runID]
    }

    /// Retains main-actor execution until the operation finishes and then clears ownership.
    /// Requires no existing executing run and ignores new work after closing admission.
    func startTrackedExecution(
        runID: UUID,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        guard !isClosing else { return }
        precondition(executingRunID == nil, "Only one developer runner execution may be active.")
        executingRunID = runID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.runTasks[runID] = nil
                if self.executingRunID == runID {
                    self.executingRunID = nil
                }
            }
            await operation()
        }
        runTasks[runID] = task
    }

    /// Publishes progress only for the executing run and does not overwrite an already cancelled UI phase.
    private func updateProgress(runID: UUID, completed: Int, total: Int) {
        guard executingRunID == runID,
              activeRuns[runID]?.phase != .cancelled else { return }
        activeRuns[runID]?.phase = .running
        activeRuns[runID]?.completedSamples = completed
        activeRuns[runID]?.totalSamples = total
    }

    /// Projects terminal evidence or failure into the tracked run's status without changing task ownership.
    private func projectCompletion(_ result: Result<EvaluationRun, Error>, for runID: UUID) {
        Self.projectCompletion(result, status: &activeRuns[runID])
    }

    /// Projects terminal state only; callers retain task lifetime and return/throw ownership.
    static func projectCompletion(
        _ result: Result<EvaluationRun, Error>,
        status: inout DeveloperRunStatus?
    ) {
        switch result {
        case .success(let run):
            status?.completedSamples = run.results.count
            status?.detail = run.terminationReason
            if run.cancelled {
                status?.phase = .cancelled
                status?.detail = run.terminationReason ?? "cancelled"
                return
            }
            switch run.terminationReason {
            case "cancelled", "developerRunner:cancelled": status?.phase = .cancelled
            case "developerRunner:deadlineExceeded": status?.phase = .timedOut
            case "developerRunner:disconnected": status?.phase = .disconnected
            case .some: status?.phase = .failed
            case nil: status?.phase = .completed
            }
        case .failure(let error):
            if error is CancellationError {
                status?.phase = .cancelled
                status?.detail = "Run cancelled."
            } else if let failure = error as? DeveloperExecutionFailure {
                status?.phase = phase(for: failure.code)
                status?.detail = failure.message
            } else {
                status?.phase = .failed
                status?.detail = error.localizedDescription
            }
        }
    }

    /// Maps cancellation, deadline, and disconnect failures to distinct UI phases; other codes become failed.
    private static func phase(for code: DeveloperExecutionErrorCode) -> DeveloperRunPhase {
        switch code {
        case .cancelled: .cancelled
        case .deadlineExceeded: .timedOut
        case .disconnected: .disconnected
        default: .failed
        }
    }

    /// Loads a saved desktop UUID or generates one and attempts to persist it.
    /// A storage failure still returns the generated session identity.
    private static func loadOrCreateDesktopID(at url: URL) -> UUID {
        if let value = try? String(contentsOf: url, encoding: .utf8),
           let id = UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return id
        }
        let id = UUID()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? id.uuidString.write(to: url, atomically: true, encoding: .utf8)
        return id
    }
}
