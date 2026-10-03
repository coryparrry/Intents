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
    var records: [ProductionRecord] = []
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
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var refreshID = UUID()
    init(root: URL) {
        do { storage = try ProductionStorage(root: root.appendingPathComponent("ProductionEvals")) }
        catch { storage = nil; self.error = error.localizedDescription }
    }
    var selectedJob: ProductionJob? { jobs.first { $0.id == selectedJobID } }
    func refresh() async {
        guard let storage else { return }
        let token = UUID(); refreshID = token
        let selectedID = selectedJobID, page = offset
        isLoading = true
        do {
            let snapshot = try await Task.detached(priority: .utility) {
                let datasets = try storage.datasets(), jobs = try storage.jobs(), workers = try storage.workers(), schedules = try storage.schedules()
                let report = try selectedID.map { try storage.report(jobID: $0) }
                let records = try selectedID.map { try storage.records(jobID: $0, offset: page, limit: 50) } ?? []
                return (datasets,jobs,workers,schedules,report,records)
            }.value
            guard refreshID == token else { return }
            (datasets,jobs,workers,schedules,report,records) = snapshot
            if let record = selectedRecord, let id = selectedJobID { review = try storage.review(jobID: id, requestID: record.response.requestID) }
        } catch { if refreshID == token { self.error = error.localizedDescription } }
        if refreshID == token { isLoading = false }
    }
    func select(_ id: UUID) { selectedJobID = id; offset = 0; selectedRecord = nil; review = nil; report = nil; Task { await refresh() } }
    func selectRecord(_ record: ProductionRecord) {
        selectedRecord = record; selectedExample = nil; review = nil
        guard let job = selectedJob, let storage else { return }
        Task {
            do {
                let value = try await Task.detached(priority: .utility) {
                    let reader = try ProductionDatasetReader(storage: storage, revision: job.datasetRevision)
                    let example = try reader.example(at: record.slot / (job.configuration.repetitions * job.configuration.targets.count))
                    return (example, try storage.review(jobID: job.id, requestID: record.response.requestID))
                }.value
                guard selectedJobID == job.id, selectedRecord?.slot == record.slot else { return }
                selectedExample = value.0; review = value.1
            } catch { self.error = error.localizedDescription }
        }
    }

    func perform<T: Sendable>(_ operation: @escaping @Sendable (ProductionStorage) throws -> T,
                              completed: @escaping @MainActor (T) -> Void = { _ in }) {
        guard let storage else { return }
        Task {
            do { let result = try await Task.detached(priority: .utility) { try operation(storage) }.value; completed(result); await refresh() }
            catch { self.error = error.localizedDescription }
        }
    }
    func importDataset(file: URL, name: String, version: String, sampling: ProductionSampling, productionData: Bool, confirmed: Bool) {
        perform { try $0.importDataset(from: file, name: name, version: version, sampling: sampling, productionData: productionData, redactionConfirmed: confirmed) }
    }
    func snapshotDataset(store: EvaluationStore) {
        let suite = store.draftSuite
        perform { storage in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("suite-dataset-\(UUID().uuidString).jsonl")
            defer { try? FileManager.default.removeItem(at: file) }
            var data = Data()
            for example in suite.cases {
                let value = ProductionExample(id: example.id.uuidString, prompt: example.prompt, expected: example.expected,
                    metadata: ["task": example.name], input: try ProductionCodec.encode(example))
                data.append(try ProductionCodec.encode(value)); data.append(10)
            }
            try data.write(to: file)
            return try storage.importDataset(from: file, name: suite.name, version: suite.version)
        }
    }
    func nativeConfiguration(store: EvaluationStore) throws -> ProductionJobConfiguration {
        let context = try store.productionSnapshot(), data = try ProductionCodec.encode(context)
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
        perform({ try $0.createJob(name: name, datasetRevision: dataset, configuration: frozen) }, completed: { self.select($0.id) })
    }
    func duplicateJob() {
        guard let job = selectedJob else { return }
        perform({ try $0.createJob(name: job.name + " · repeat", datasetRevision: job.datasetRevision, configuration: job.configuration) }, completed: { self.select($0.id) })
    }
    func createCaptured(_ dataset: ProductionDataset) {
        perform({ try $0.createCapturedJob(name: dataset.name + " · captured review", datasetRevision: dataset.revision) }, completed: { self.select($0.id) })
    }
    func setControl(paused: Bool? = nil, cancelled: Bool? = nil, completed: @escaping @MainActor () -> Void = {}) {
        guard let id = selectedJobID else { return }
        perform({ try $0.setControl(jobID: id, paused: paused, cancelled: cancelled) }, completed: { _ in completed() })
        if id == runningJobID && (paused == true || cancelled == true) { runTask?.cancel() }
    }
    func run(store: EvaluationStore, externalDisclosureApproved: Bool) {
        guard let job = selectedJob else { return }
        do { try start(job: job, store: store, externalDisclosureApproved: externalDisclosureApproved) }
        catch { self.error = error.localizedDescription }
    }
    func interrupt(jobID: UUID) { if jobID == runningJobID { runTask?.cancel() } }
    func start(job: ProductionJob, store: EvaluationStore, externalDisclosureApproved: Bool) throws {
        guard let storage, runTask == nil else { throw EvaluationStoreError.runBusy }
        do {
            let kind = (try JSONSerialization.jsonObject(with: job.configuration.executionContext) as? [String: Any])?["kind"] as? String
            let executor: ProductionExecutor
            let owner: UUID?
            let worker: ProductionWorker
            if kind == "captured-output-review-v1" {
                owner = nil; executor = ProductionStorage.capturedResponse
                worker = .init(id: "captured-review", name: "Imported outputs", platform: "captured", operatingSystem: "source metadata", hardware: "source metadata", locale: "source metadata", model: "original output")
            } else if kind == "native-suite-v1" {
                let context = try ProductionCodec.decode(NativeProductionContext.self, job.configuration.executionContext)
                let admission = try store.beginProductionExecution(context, externalDisclosureApproved: externalDisclosureApproved)
                owner = admission.0
                do { let runner = try NativeProductionExecutor(context: context, executionRevision: job.configuration.executionRevision, judge: admission.1); executor = { try await runner.execute($0) } }
                catch { store.endProductionExecution(admission.0); throw error }
                #if arch(arm64)
                let hardware = "Apple silicon"
                #else
                let hardware = "Intel"
                #endif
                worker = .init(id: localWorkerID, name: "This Mac", platform: "macOS", operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                    hardware: hardware, locale: Locale.current.identifier, model: context.reportedModel)
            } else { throw ProductionFailure.unavailable("Run this job with its configured command worker. The worker instructions are in the production eval guide.") }
            executionErrors[job.id] = nil
            runningJobID = job.id
            runTask = Task {
                defer { if let owner { store.endProductionExecution(owner) }; runningJobID = nil; runTask = nil }
                do {
                    let task = Task.detached(priority: .utility) {
                        try await ProductionBatchRunner(storage: storage).run(jobID: job.id, worker: worker, execute: executor)
                    }
                    _ = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                } catch is CancellationError { } catch { self.error = error.localizedDescription; executionErrors[job.id] = error.localizedDescription }
                await refresh()
            }
        } catch { throw error }
    }
    func appendReview(action: ProductionReviewAction, reviewer: String, assignee: String, outcome: ProductionOutcome,
                      note: String, tags: String, verifiedOutput: String, verifiedCost: Double?) {
        guard let jobID = selectedJobID, let record = selectedRecord else { return }
        let response: ProductionResponse? = action == .reconcile ? .init(requestID: record.response.requestID, outcome: outcome,
            output: verifiedOutput, explanation: note, latencyMilliseconds: record.response.latencyMilliseconds, cost: verifiedCost) : nil
        let event = ProductionReviewEvent(requestID: record.response.requestID, reviewer: reviewer, action: action, assignee: action == .assign ? assignee : nil,
            outcome: action == .assign || action == .reconcile ? nil : outcome, note: note,
            tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }, reconciledResponse: response)
        perform { try $0.appendReview(jobID: jobID, slot: record.slot, event: event) }
    }
    func export() {
        guard let id = selectedJobID else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "eval-evidence-\(id.uuidString.prefix(8))"
        panel.title = "Export dataset, results and review history"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try $0.exportJob(id, to: url) }
    }
}
