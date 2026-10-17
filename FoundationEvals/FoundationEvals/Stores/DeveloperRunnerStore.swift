import Foundation
#if canImport(FoundationEvalsDeveloper)
import FoundationEvalsDeveloper
#endif
import Observation

enum EvaluationRunTarget: Hashable, Identifiable, Sendable {
    case local
    case runner(UUID)

    var id: String {
        switch self {
        case .local: "local"
        case .runner(let id): "runner:\(id.uuidString)"
        }
    }
}

@MainActor
@Observable
final class DeveloperRunnerStore {
    let client: DeveloperRunnerClient
    private(set) var activeRuns: [UUID: DeveloperRunStatus] = [:]
    private(set) var executingRunID: UUID?
    var selectedFeatureID: String?
    var automationExecutionBlocked = false {
        didSet { ScenarioExecutionAdmission.shared.setAutomationBlocked(automationExecutionBlocked, ownerID: automationAdmissionID) }
    }
    @ObservationIgnored private let automationAdmissionID = UUID()

    @ObservationIgnored private let evaluationStore: EvaluationStore
    @ObservationIgnored private var isClosing = false
    @ObservationIgnored private var runTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var snapshotTasks: [UUID: Task<EvaluationRun, Error>] = [:]

    init(
        evaluationStore: EvaluationStore,
        desktopID: UUID? = nil,
        client: DeveloperRunnerClient? = nil
    ) {
        self.evaluationStore = evaluationStore
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

    var runners: [DeveloperRunnerSnapshot] { client.runners }

    var selectedRunnerID: UUID? {
        get { client.selectedRunnerID }
        set { client.selectedRunnerID = newValue }
    }

    var pairingChallenges: [UUID: DeveloperPairingChallenge] {
        client.pendingPairingChallenges
    }

    var runTargets: [EvaluationRunTarget] {
        [.local] + runners.filter { $0.state == .connected }.map { .runner($0.id) }
    }

    var isBrowsing: Bool { client.isBrowsing }
    var lastError: String? { client.lastError }

    func start() {
        guard !isClosing else { return }
        client.startBrowsing()
    }

    func stop() {
        for task in runTasks.values {
            task.cancel()
        }
        for task in snapshotTasks.values {
            task.cancel()
        }
        if runTasks.isEmpty && snapshotTasks.isEmpty {
            executingRunID = nil
        }
        client.shutdown()
    }

    /// Closes admission and waits for owned work to retain its terminal evidence.
    func closeAndWait() async {
        isClosing = true
        let runs = Array(runTasks.values)
        let snapshots = Array(snapshotTasks.values)
        stop()
        for task in runs { await task.value }
        for task in snapshots { _ = try? await task.value }
    }

    /// Connects to a discovered endpoint. Pairing remains incomplete until the
    /// user enters the code displayed by the runner app in `trustRunner`.
    func beginPairing(with runnerID: UUID) throws {
        guard !isClosing else { throw EvaluationStoreError.resourceConflict("Developer runners are closing.") }
        try client.connect(to: runnerID)
    }

    func cancelPairing(with runnerID: UUID) {
        client.disconnect(runnerID)
    }

    func trustRunner(_ runnerID: UUID, pairingCode: String) throws {
        guard !isClosing else { throw EvaluationStoreError.resourceConflict("Developer runners are closing.") }
        try client.trustRunner(runnerID, pairingCode: pairingCode)
    }

    func disconnect(_ runnerID: UUID) {
        client.disconnect(runnerID)
    }

    func forgetTrust(for runnerID: UUID) throws {
        try client.forgetTrust(for: runnerID)
    }

    @discardableResult
    func runSelectedSuite(
        on runnerID: UUID,
        featureID: String,
        timeout: Duration = .seconds(120)
    ) throws -> UUID {
        guard !isClosing, ScenarioExecutionAdmission.shared.allows(nil),
              executingRunID == nil, !evaluationStore.hasActiveExecution, !automationExecutionBlocked else {
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

        startTrackedExecution(runID: runID) { [weak self] in
            guard let self else { return }
            self.activeRuns[runID]?.phase = .dispatching
            do {
                let run = try await self.evaluationStore.runDeveloperFeature(
                    id: runID,
                    expectedRevision: revision,
                    runner: runner,
                    feature: feature,
                    client: self.client,
                    timeout: timeout
                ) { [weak self] completed, total in
                    await self?.updateProgress(runID: runID, completed: completed, total: total)
                }
                self.projectCompletion(.success(run), for: runID)
            } catch {
                self.projectCompletion(.failure(error), for: runID)
            }
        }
        return runID
    }

    func cancelRun(_ runID: UUID) {
        runTasks[runID]?.cancel()
        snapshotTasks[runID]?.cancel()
        activeRuns[runID]?.phase = .cancelled
        activeRuns[runID]?.detail = "Cancellation requested."
    }

    /// Runs a frozen suite against an explicitly selected runner and feature.
    /// The supplied adapter may use the negotiated, expectation-free subject
    /// input. This method does not read or update the UI's selected suite.
    func runFeatureSnapshot(
        id: UUID,
        projectID: UUID,
        suite: EvaluationSuite,
        expectedRevision: String,
        runnerID: UUID,
        featureID: String,
        executionOwnerID: UUID? = nil,
        adapter: any EvaluationFeatureAdapter
    ) async throws -> EvaluationRun {
        guard !isClosing, ScenarioExecutionAdmission.shared.allows(executionOwnerID),
              !automationExecutionBlocked, executingRunID == nil else {
            throw EvaluationStoreError.resourceConflict("Another developer runner execution is active.")
        }
        guard let runner = runners.first(where: { $0.id == runnerID && $0.state == .connected }) else {
            throw DeveloperExecutionFailure(code: .disconnected, message: "Connect the runner before starting a run.")
        }
        guard runner.features.contains(where: { $0.id == featureID }) else {
            throw DeveloperExecutionFailure(
                code: .featureNotFound,
                message: "The selected feature is not available on this runner."
            )
        }
        executingRunID = id
        activeRuns[id] = .init(
            id: id, runnerID: runnerID, featureID: featureID, phase: .preparing,
            completedSamples: 0, totalSamples: suite.cases.count * suite.repetitions
        )
        let evaluationStore = self.evaluationStore
        let task = Task<EvaluationRun, Error> { @MainActor [weak self] in
            try await evaluationStore.runFeatureAdapterSnapshot(
                id: id, projectID: projectID, suite: suite,
                expectedRevision: expectedRevision,
                executionOwnerID: executionOwnerID, adapter: adapter
            ) { [weak self] completed, total in
                await self?.updateProgress(runID: id, completed: completed, total: total)
            }
        }
        snapshotTasks[id] = task
        activeRuns[id]?.phase = .dispatching
        defer {
            snapshotTasks[id] = nil
            if executingRunID == id { executingRunID = nil }
        }
        do {
            let run = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            projectCompletion(.success(run), for: id)
            return run
        } catch is CancellationError {
            projectCompletion(.failure(CancellationError()), for: id)
            throw CancellationError()
        } catch {
            projectCompletion(.failure(error), for: id)
            throw error
        }
    }

    func status(for runID: UUID) -> DeveloperRunStatus? {
        activeRuns[runID]
    }

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

    private func updateProgress(runID: UUID, completed: Int, total: Int) {
        guard executingRunID == runID,
              activeRuns[runID]?.phase != .cancelled else { return }
        activeRuns[runID]?.phase = .running
        activeRuns[runID]?.completedSamples = completed
        activeRuns[runID]?.totalSamples = total
    }

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

    private static func phase(for code: DeveloperExecutionErrorCode) -> DeveloperRunPhase {
        switch code {
        case .cancelled: .cancelled
        case .deadlineExceeded: .timedOut
        case .disconnected: .disconnected
        default: .failed
        }
    }

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
