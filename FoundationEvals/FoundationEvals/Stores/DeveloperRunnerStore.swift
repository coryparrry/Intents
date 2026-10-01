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

    @ObservationIgnored private let evaluationStore: EvaluationStore
    @ObservationIgnored private var runTasks: [UUID: Task<Void, Never>] = [:]

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
        client.startBrowsing()
    }

    func stop() {
        for task in runTasks.values {
            task.cancel()
        }
        if runTasks.isEmpty {
            executingRunID = nil
        }
        client.shutdown()
    }

    /// Connects to a discovered endpoint. Pairing remains incomplete until the
    /// user enters the code displayed by the runner app in `trustRunner`.
    func beginPairing(with runnerID: UUID) throws {
        try client.connect(to: runnerID)
    }

    func cancelPairing(with runnerID: UUID) {
        client.disconnect(runnerID)
    }

    func trustRunner(_ runnerID: UUID, pairingCode: String) throws {
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
        guard executingRunID == nil, !evaluationStore.isRunning else {
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
                self.activeRuns[runID]?.completedSamples = run.results.count
                self.activeRuns[runID]?.detail = run.terminationReason
                switch run.terminationReason {
                case "cancelled", "developerRunner:cancelled":
                    self.activeRuns[runID]?.phase = .cancelled
                case "developerRunner:deadlineExceeded":
                    self.activeRuns[runID]?.phase = .timedOut
                case "developerRunner:disconnected":
                    self.activeRuns[runID]?.phase = .disconnected
                case .some:
                    self.activeRuns[runID]?.phase = .failed
                case nil:
                    self.activeRuns[runID]?.phase = .completed
                }
            } catch is CancellationError {
                self.activeRuns[runID]?.phase = .cancelled
                self.activeRuns[runID]?.detail = "Run cancelled."
            } catch let failure as DeveloperExecutionFailure {
                self.activeRuns[runID]?.phase = Self.phase(for: failure.code)
                self.activeRuns[runID]?.detail = failure.message
            } catch {
                self.activeRuns[runID]?.phase = .failed
                self.activeRuns[runID]?.detail = error.localizedDescription
            }
        }
        return runID
    }

    func cancelRun(_ runID: UUID) {
        runTasks[runID]?.cancel()
        activeRuns[runID]?.phase = .cancelled
        activeRuns[runID]?.detail = "Cancellation requested."
    }

    func status(for runID: UUID) -> DeveloperRunStatus? {
        activeRuns[runID]
    }

    func startTrackedExecution(
        runID: UUID,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) {
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
        activeRuns[runID]?.phase = .running
        activeRuns[runID]?.completedSamples = completed
        activeRuns[runID]?.totalSamples = total
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
