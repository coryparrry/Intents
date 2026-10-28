import AppKit
import Foundation
import Observation

@MainActor @Observable
final class ProductionWorkspaceStore {
    var pane: ProductionPane = .datasets
    let storage: ProductionStorage?
    var datasets: [ProductionDataset] = []
    var jobs: [ProductionJob] = []
    var workers: [ProductionWorker] = []
    var schedules: [ProductionSchedule] = []
    var selectedJobID: UUID?
    var report: ProductionReport?
    var progress: ProductionProgress?
    var runningProgress: ProductionProgress?
    var records: [ProductionRecord] = []
    private var outcomesByRequestID: [UUID: ProductionOutcome] = [:]
    var selectedRecord: ProductionRecord?
    var selectedExample: ProductionExample?
    var review: ProductionReviewResolution?
    var offset = 0
    var error: String?
    var isLoading = false
    var runningJobID: UUID?
    private(set) var executionErrors: [UUID:String] = [:]
    @ObservationIgnored private let localWorkerID: String = {
        let key = "production-eval-worker-id"
        if let value = UserDefaults.standard.string(forKey: key) { return value }
        let value = UUID().uuidString; UserDefaults.standard.set(value, forKey: key); return value
    }()
    @ObservationIgnored private var isClosing = false
    @ObservationIgnored private var operationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var refreshID = UUID()
    @ObservationIgnored private let capturedExecutor: ProductionExecutor
    @ObservationIgnored private let telemetry: TelemetryController?
    /// Opens production storage beneath root and retains optional content-free telemetry and the captured-output executor.
    /// Storage initialization failure leaves storage unavailable and publishes its error on the main actor.
    init(root: URL, telemetry: TelemetryController? = nil,
         capturedExecutor: @escaping ProductionExecutor = ProductionStorage.capturedResponse) {
        self.capturedExecutor = capturedExecutor
        self.telemetry = telemetry
        do { storage = try ProductionStorage(root: root.appendingPathComponent("ProductionEvals")) }
        catch { storage = nil; self.error = error.localizedDescription }
    }
    var selectedJob: ProductionJob? { jobs.first { $0.id == selectedJobID } }
    /// Loads a consistent workspace snapshot; the active Jobs pane uses counts while result and report panes retain audited evidence.
    func refresh() async {
        guard !isClosing, let storage else { return }
        let token = UUID(); refreshID = token
        let selectedID = selectedJobID, page = offset, activeID = runningJobID, expectedPane = pane
        let polling = runningJobID == selectedID && runningJobID != nil && expectedPane == .jobs
        isLoading = true
        defer { if refreshID == token { isLoading = false } }
        do {
            let snapshot = try await Task.detached(priority: .utility) {
                let datasets = try storage.datasets(), jobs = try storage.jobs(), workers = try storage.workers(), schedules = try storage.schedules()
                let report: ProductionReport? = try selectedID.flatMap { polling ? nil : try storage.report(jobID: $0) }
                let runningProgress = try activeID.map { try storage.progress(jobID: $0) }
                let progress: ProductionProgress? = polling ? runningProgress : nil
                let records = try selectedID.map { polling ? [] : try storage.records(jobID: $0, offset: page, limit: 50) } ?? []
                var outcomes: [UUID: ProductionOutcome] = [:]
                if let selectedID {
                    for record in records {
                        let review = try storage.review(jobID: selectedID, requestID: record.response.requestID)
                        outcomes[record.response.requestID] = review.outcome ?? review.response?.outcome ?? record.response.outcome
                    }
                }
                return (datasets,jobs,workers,schedules,report,progress,runningProgress,records,outcomes)
            }.value
            guard !isClosing, refreshID == token, selectedJobID == selectedID, offset == page, runningJobID == activeID, pane == expectedPane else { return }
            (datasets,jobs,workers,schedules,report,progress,runningProgress,records,outcomesByRequestID) = snapshot
            if let record = selectedRecord, let id = selectedJobID { review = try storage.review(jobID: id, requestID: record.response.requestID) }
        } catch {
            if !isClosing, refreshID == token, selectedJobID == selectedID, offset == page, pane == expectedPane {
                self.error = error.localizedDescription
            }
        }
    }
    /// Uses the same review/reconciliation precedence as the audit without changing the original saved record.
    func outcome(for record: ProductionRecord) -> ProductionOutcome {
        outcomesByRequestID[record.response.requestID] ?? record.response.outcome
    }
    /// Selects a batch and clears prior details before asynchronously loading its first result page.
    func select(_ id: UUID) {
        guard !isClosing else { return }
        refreshID = UUID()
        selectedJobID = id; offset = 0; records = []; selectedRecord = nil; selectedExample = nil; review = nil; report = nil
        progress = nil; outcomesByRequestID = [:]
        Task { await refresh() }
    }
    /// Opens a saved batch directly in Results and loads its report and records.
    func showResults(for id: UUID) {
        pane = .review
        select(id)
    }
    /// Clears selected response evidence so a delayed detail load cannot reopen a dismissed result.
    func dismissResult() {
        selectedRecord = nil; selectedExample = nil; review = nil
    }
    /// Updates counts for the executing batch without replacing an older batch currently being inspected.
    func refreshRunningProgress() async {
        guard !isClosing, let id = runningJobID, let storage else { return }
        do {
            let value = try await Task.detached(priority: .utility) { try storage.progress(jobID: id) }.value
            guard !isClosing, runningJobID == id else { return }
            runningProgress = value
            if selectedJobID == id && pane == .jobs { progress = value }
        } catch { if !isClosing, runningJobID == id { self.error = error.localizedDescription } }
    }
    /// Selects a record belonging to the current batch and returns a task loading its example and review off the main actor.
    /// Returns nil for unavailable admission or mismatched batch identity and ignores superseded detail completions.
    @discardableResult
    func selectRecord(_ record: ProductionRecord) -> Task<Void, Never>? {
        guard !isClosing, let job = selectedJob, let storage else { return nil }
        guard (0..<job.plannedCount).contains(record.slot),
              record.response.requestID == storage.requestID(job, slot: record.slot) else {
            error = "This result belongs to another batch. Select a result from the current batch."
            return nil
        }
        selectedRecord = record; selectedExample = nil; review = nil
        return Task {
            do {
                let value = try await Task.detached(priority: .utility) {
                    let reader = try ProductionDatasetReader(storage: storage, revision: job.datasetRevision)
                    let example = try reader.example(at: record.slot / (job.configuration.repetitions * job.configuration.targets.count))
                    return (example, try storage.review(jobID: job.id, requestID: record.response.requestID))
                }.value
                guard !isClosing, selectedJobID == job.id, selectedRecord?.slot == record.slot else { return }
                selectedExample = value.0; review = value.1
            } catch {
                guard !isClosing, selectedJobID == job.id, selectedRecord?.response.requestID == record.response.requestID else { return }
                self.error = error.localizedDescription
            }
        }
    }

    /// Runs a storage operation off the main actor, then delivers completed and refresh on the main actor.
    /// Optional telemetry ends after durable work and before refresh; the typed result decides whether successful work counts feature use.
    /// Shutdown drains admitted work even when UI publication closes.
    /// Returns nil when closing or storage is absent; untagged operations do not emit telemetry.
    @discardableResult
    func perform<T: Sendable>(_ operation: @escaping @Sendable (ProductionStorage) throws -> T,
                              telemetryOperation: TelemetryOperation? = nil,
                              recordsFeature: @escaping @MainActor (T) -> Bool = { _ in true },
                              completed: @escaping @MainActor (T) -> Void = { _ in }) -> Task<Void, Never>? {
        guard !isClosing, let storage else { return nil }
        let span = telemetryOperation.flatMap { telemetry?.begin($0) }
        return trackOperation {
            do {
                let result = try await Task.detached(priority: .utility) { try operation(storage) }.value
                self.telemetry?.end(span, recordsFeature: recordsFeature(result))
                guard !self.isClosing else { return }
                completed(result)
                await self.refresh()
            } catch {
                self.telemetry?.end(span, failure: Self.executionFailure(error))
                self.error = error.localizedDescription
            }
        }
    }
    /// Tracks an admitted main-actor operation until completion so shutdown can drain its storage work.
    /// Returns an empty task instead of admitting new work after closing.
    @discardableResult
    private func trackOperation(_ operation: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        guard !isClosing else { return Task {} }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            defer { self?.operationTasks[id] = nil }
            await operation()
        }
        operationTasks[id] = task
        return task
    }

    /// Cancels execution and drains already admitted storage writes before exit.
    /// Interrupted slots keep the runner's existing journal/reconciliation policy.
    func closeAndWait() async {
        isClosing = true
        refreshID = UUID()
        isLoading = false
        let running = runTask
        let operations = Array(operationTasks.values)
        running?.cancel()
        if let running { await running.value }
        for task in operations { await task.value }
    }

    /// Schedules dataset import with version, sampling, production-data flag, and redaction confirmation passed to storage.
    /// Records adoption only for a newly published revision and returns the tracked disk operation; duplicate imports remain successful diagnostics.
    @discardableResult
    func importDataset(file: URL, name: String, version: String, sampling: ProductionSampling, productionData: Bool, confirmed: Bool) -> Task<Void, Never>? {
        perform({ try $0.importDatasetWithOutcome(from: file, name: name, version: version, sampling: sampling, productionData: productionData, redactionConfirmed: confirmed) },
                telemetryOperation: .datasetImport, recordsFeature: { $0.didPublish })
    }
    /// Snapshots draft cases into a temporary JSONL dataset and imports it through tracked storage work.
    /// Captures the draft before dispatch, counts only newly published revisions, and returns tracked work that cleans up its temporary input.
    @discardableResult
    func snapshotDataset(store: EvaluationStore) -> Task<Void, Never>? {
        let suite = store.draftSuite
        guard !suite.hasDocumentCases else {
            error = "Document suites cannot be flattened into production datasets. Run or export the document suite in Cases."
            return nil
        }
        return perform({ storage in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("suite-dataset-\(UUID().uuidString).jsonl")
            defer { try? FileManager.default.removeItem(at: file) }
            var data = Data()
            for example in suite.cases {
                let value = ProductionExample(id: example.id.uuidString, prompt: example.prompt, expected: example.expected,
                    metadata: ["task": example.name], input: try ProductionCodec.encode(example))
                data.append(try ProductionCodec.encode(value)); data.append(10)
            }
            try data.write(to: file)
            return try storage.importDatasetWithOutcome(from: file, name: suite.name, version: suite.version)
        }, telemetryOperation: .datasetImport, recordsFeature: { $0.didPublish })
    }
    /// Freezes an explicit suite or the native UI draft into verified execution setup and scoring digests.
    /// Copies release gates and marks HTTP model/tool execution as potentially side-effecting; snapshot or encoding errors propagate.
    func nativeConfiguration(store: EvaluationStore, suite: EvaluationSuite? = nil) throws -> ProductionJobConfiguration {
        let context = try store.productionSnapshot(of: suite ?? store.draftSuite), data = try ProductionCodec.encode(context)
        struct Scoring: Codable { var mode: ScoringMode; var criteria: String; var judge: EvaluationJudgeConfiguration; var features: EvaluationFeatureConfiguration }
        let scoring = Scoring(mode: context.suite.scoringMode, criteria: context.suite.criteria, judge: context.suite.judgeConfiguration, features: context.suite.features)
        var configuration = ProductionJobConfiguration(scoringRevision: ProductionCodec.digest(try ProductionCodec.encode(scoring)),
            executionRevision: ProductionCodec.digest(data), executionContext: data)
        if context.suite.modelConfiguration.provider == .customHTTP || context.suite.features.tools.contains(where: { $0.mode == .localHTTP }) { configuration.replaySafety = .sideEffects }
        let policy = context.suite.releasePolicy
        configuration.gate.maximumErrors = policy.maximumErrorCount
        configuration.gate.criticalSourceIDs = policy.criticalCaseIDs.map(\.uuidString)
        configuration.gate.maximumAverageMilliseconds = policy.maximumAverageLatencyMilliseconds
        configuration.gate.requireBaseline = policy.requireApprovedBaseline
        configuration.gate.maximumPassRateRegression = policy.maximumPassRateRegression
        return configuration
    }
    /// Creates a batch using frozen native setup and the supplied dataset, targets, budgets, baseline, and cohort gates.
    /// Pass-rate inputs are percentages and budgetHours is converted to seconds; successful storage completion selects the new job.
    func createJob(store: EvaluationStore, dataset: String, name: String, repetitions: Int, passRate: Double,
                   timeout: Double, budgetHours: Double, baseline: UUID?, targets: [ProductionTarget],
                   requiredCohortKey: String, requiredCohortValue: String, cohortPassRate: Double) throws {
        var configuration = try nativeConfiguration(store: store)
        configuration.repetitions = repetitions
        configuration.timeoutSeconds = timeout; configuration.maximumElapsedSeconds = budgetHours * 3600
        configuration.targets = targets; configuration.baselineJobID = baseline; configuration.gate.minimumPassRate = passRate/100
        if !requiredCohortKey.isEmpty {
            configuration.gate.requiredCohorts[requiredCohortKey] = requiredCohortValue
            configuration.gate.cohortMinimumPassRates[requiredCohortKey + "=" + requiredCohortValue] = cohortPassRate/100
        }
        let frozen = configuration
        perform({ storage in
            return try storage.createJob(name: name, datasetRevision: dataset, configuration: frozen, resolveCriticalCaseIDs: true)
        }, completed: { self.select($0.id) })
    }
    /// Clones the named frozen job, defaulting to the selection, and selects the new batch.
    func duplicateJob(jobID: UUID? = nil) {
        guard let id = jobID ?? selectedJobID, let job = jobs.first(where: { $0.id == id }) else { return }
        perform({ try $0.createJob(name: job.name + " · repeat", datasetRevision: job.datasetRevision, configuration: job.configuration) }, completed: { self.select($0.id) })
    }
    /// Creates and selects a captured-output review job for the supplied dataset revision.
    func createCaptured(_ dataset: ProductionDataset) {
        perform({ try $0.createCapturedJob(name: dataset.name + " · captured review", datasetRevision: dataset.revision) }, completed: { self.select($0.id) })
    }
    /// Applies pause or cancellation to an explicit job or the selection, interrupting only that local execution.
    @discardableResult
    func setControl(jobID: UUID? = nil, paused: Bool? = nil, cancelled: Bool? = nil, completed: @escaping @MainActor () -> Void = {}) -> Task<Void, Never>? {
        guard let id = jobID ?? selectedJobID else { return nil }
        return perform({ try $0.setControl(jobID: id, paused: paused, cancelled: cancelled) }, completed: { _ in
            if paused == true || cancelled == true { self.interrupt(jobID: id) }
            completed()
        })
    }
    /// Schedules a pause change using the supplied schedule's digest as the expected revision, reporting conflicts through error.
    func setSchedulePaused(_ schedule: ProductionSchedule, paused: Bool) {
        perform { storage in
            let expectedRevision = try ProductionCodec.digest(ProductionCodec.encode(schedule))
            var updated = schedule; updated.paused = paused
            try storage.saveSchedule(updated, expectedRevision: expectedRevision)
        }
    }
    /// Verifies the frozen job revision off the main actor, then admits local execution before unpausing storage.
    /// Returns the tracked resume task and publishes admission or revision errors on the main actor.
    @discardableResult
    func resume(job: ProductionJob, store: EvaluationStore, externalDisclosureApproved: Bool) -> Task<Void, Never> {
        trackOperation { [self] in
            guard !isClosing else { return }
            do {
                guard let storage else { throw ProductionFailure.unavailable("Production storage is unavailable.") }
                try await Task.detached(priority: .utility) {
                    let current = try storage.loadJob(job.id)
                    guard current.revision == job.revision else { throw ProductionFailure.integrity("Frozen job changed before resume.") }
                }.value
                try start(job: job, store: store, externalDisclosureApproved: externalDisclosureApproved, resuming: true)
            } catch { self.error = error.localizedDescription }
        }
    }
    /// Schedules baseline approval bound to the report's job and evidence revisions; does nothing without evidence revision.
    func approveBaseline(_ report: ProductionReport, note: String) {
        guard let evidence = report.evidenceRevision else { return }
        perform { try $0.approveBaseline(jobID: report.job.id, expectedJobRevision: report.job.revision,
                                       expectedEvidenceRevision: evidence, note: note) }
    }
    /// Starts the selected production job locally and publishes admission errors, leaving unavailable selections unchanged.
    func run(store: EvaluationStore, externalDisclosureApproved: Bool) {
        guard let job = selectedJob else { return }
        do { try start(job: job, store: store, externalDisclosureApproved: externalDisclosureApproved) }
        catch { self.error = error.localizedDescription }
    }
    /// Requests cancellation only when jobID matches the current local execution.
    func interrupt(jobID: UUID) { if jobID == runningJobID { runTask?.cancel() } }
    /// Joins the currently admitted local batch without cancelling it or admitting additional work.
    func waitForRun() async { await runTask?.value }
    /// Admits and starts a matching native or captured worker; completion releases ownership before loading its final audit.
    /// Records terminal diagnostics after durable results are audited; only newly completed batches count as successful feature use.
    func start(job: ProductionJob, store: EvaluationStore, externalDisclosureApproved: Bool, resuming: Bool = false) throws {
        guard !isClosing, let storage, runTask == nil else { throw EvaluationStoreError.runBusy }
        let span = store.telemetry?.begin(.batchRun)
        var owner: UUID?
        do {
            let kind = (try JSONSerialization.jsonObject(with: job.configuration.executionContext) as? [String: Any])?["kind"] as? String
            let executor: ProductionExecutor
            let worker: ProductionWorker
            if kind == "captured-output-review-v1" {
                owner = nil; executor = capturedExecutor
                worker = .init(id: "captured-review", name: "Imported outputs", platform: "captured", operatingSystem: "source metadata", hardware: "source metadata", locale: "source metadata", model: "original output")
            } else if kind == "native-suite-v1" {
                let context = try ProductionCodec.decode(NativeProductionContext.self, job.configuration.executionContext)
                let admission = try store.beginProductionExecution(context, externalDisclosureApproved: externalDisclosureApproved)
                owner = admission.0
                let runner = try NativeProductionExecutor(context: context, executionRevision: job.configuration.executionRevision, judge: admission.1)
                executor = { try await runner.execute($0) }
                #if arch(arm64)
                let hardware = "Apple silicon"
                #else
                let hardware = "Intel"
                #endif
                worker = .init(id: localWorkerID, name: "This Mac", platform: "macOS", operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                    hardware: hardware, locale: Locale.current.identifier, model: context.reportedModel)
            } else { throw ProductionFailure.unavailable("Run this job with its configured command worker. The worker instructions are in the production eval guide.") }
            guard job.configuration.targets.contains(where: { $0.matches(worker) }) else {
                throw ProductionFailure.unavailable("This Mac does not match any target in this batch. Use a matching worker or create a batch with matching targets.")
            }
            // Admission must succeed before reopening a paused job to local or polling workers.
            executionErrors[job.id] = nil
            runningProgress = nil
            runningJobID = job.id
            let executionOwner = owner
            runTask = Task {
                var failure: TelemetryFailure?
                var recordsFeature = false
                do {
                    let task = Task.detached(priority: .utility) {
                        // Admission must succeed before another worker can claim this job.
                        if resuming {
                            try Task.checkCancellation()
                            try storage.setControl(jobID: job.id, paused: false)
                        }
                        let committed = try await ProductionBatchRunner(storage: storage).run(jobID: job.id, worker: worker, execute: executor)
                        // Re-read durable evidence rather than treating the worker's return as a completed batch.
                        return (committed, try storage.report(jobID: job.id))
                    }
                    let (committed, report) = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                    if Task.isCancelled || report.phase == "cancelled" { failure = .cancelled }
                    else if report.counts.errors > 0 { failure = .generation }
                    else if report.counts.uncertain > 0 { failure = .evidence }
                    else if report.phase == "paused" { failure = .cancelled }
                    // Failed model assertions are valid results. Re-reading completed or partial jobs is not another completed feature.
                    recordsFeature = committed > 0 && report.completed == report.planned && failure == nil
                } catch is CancellationError {
                    failure = .cancelled
                } catch {
                    failure = Self.executionFailure(error)
                    self.error = error.localizedDescription; executionErrors[job.id] = error.localizedDescription
                }
                store.telemetry?.end(span, failure: failure, recordsFeature: recordsFeature)
                if let executionOwner { store.endProductionExecution(executionOwner) }
                runningJobID = nil
                runTask = nil
                await refresh()
            }
        } catch {
            if let owner { store.endProductionExecution(owner) }
            store.telemetry?.end(span, failure: Self.executionFailure(error))
            throw error
        }
    }
    /// Classifies typed batch admission/evidence errors without inspecting their private explanations.
    private static func executionFailure(_ error: any Error) -> TelemetryFailure {
        guard let failure = error as? ProductionFailure else { return .classify(error) }
        switch failure {
        case .invalid, .budget: return .validation
        case .integrity, .staleLease: return .evidence
        case .unavailable: return .deviceUnavailable
        }
    }
    /// Schedules a review event for the selected record, splitting comma-separated tags and including a verified response for reconciliation.
    /// Records the durable review-write outcome. Assignment stores an assignee; missing selection is a no-op.
    func appendReview(action: ProductionReviewAction, reviewer: String, assignee: String, outcome: ProductionOutcome,
                      note: String, tags: String, verifiedOutput: String, verifiedCost: Double?) {
        guard let jobID = selectedJobID, let record = selectedRecord else { return }
        let response: ProductionResponse? = action == .reconcile ? .init(requestID: record.response.requestID, outcome: outcome,
            output: verifiedOutput, explanation: note, latencyMilliseconds: record.response.latencyMilliseconds,
            latencyAvailable: record.response.latencyAvailable, cost: verifiedCost) : nil
        let event = ProductionReviewEvent(requestID: record.response.requestID, reviewer: reviewer, action: action, assignee: action == .assign ? assignee : nil,
            outcome: action == .assign || action == .reconcile ? nil : outcome, note: note,
            tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }, reconciledResponse: response)
        perform({ try $0.appendReview(jobID: jobID, slot: record.slot, event: event) }, telemetryOperation: .reviewSave)
    }
    /// Starts an instrumented export only after a destination is selected; cancelling the panel is a no-op.
    func export(jobID: UUID? = nil) {
        guard let id = jobID ?? selectedJobID else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "eval-evidence-\(id.uuidString.prefix(8))"
        panel.title = "Export dataset, results and review history"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        export(jobID: id, to: url)
    }
    /// Exports durable batch evidence to a chosen destination and records success only after publication completes.
    /// The returned tracked task supports network-free integration checks and shutdown drains the same disk operation.
    @discardableResult
    func export(jobID: UUID, to destination: URL) -> Task<Void, Never>? {
        perform({ try $0.exportJob(jobID, to: destination) }, telemetryOperation: .resultExport)
    }
}
