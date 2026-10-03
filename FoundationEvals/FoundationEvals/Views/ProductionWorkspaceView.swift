import SwiftUI
import AppKit

private enum ProductionPane: String, WorkspacePane {
    case datasets, jobs, review, reports, workers
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var subtitle: String {
        switch self {
        case .datasets: "Freeze examples and original production outputs for repeatable evaluation."
        case .jobs: "Run bounded batches and resume remaining examples."
        case .review: "Assign results, record failure patterns and resolve disagreement."
        case .reports: "Check release gates, cohorts and confidence across distinct sources."
        case .workers: "See worker provenance and scheduled runs in this store."
        }
    }
    var symbol: String {
        switch self { case .datasets: "tray.full"; case .jobs: "play.rectangle"; case .review: "person.crop.circle.badge.checkmark"; case .reports: "chart.bar"; case .workers: "desktopcomputer" }
    }
}

struct ProductionWorkspaceView: View {
    @Bindable var model: ProductionWorkspaceStore
    let store: EvaluationStore
    @State private var pane: ProductionPane = .datasets
    @State private var importURL: URL?
    @State private var creatingJob = false
    @State private var search = ""
    @State private var approvedDisclosure = false
    @State private var cancelling = false
    @State private var scheduleHours = 24.0
    @State private var scheduleRuns = 1
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("Batch runs").font(.title2.weight(.bold))
                    Spacer()
                    if model.isLoading { ProgressView().controlSize(.small) }
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }.buttonStyle(.bordered)
                }
                WorkspacePaneLayout(heading: "Batch workspace", selection: $pane) {
                    switch pane {
                    case .datasets: datasetPane
                    case .jobs: jobsPane
                    case .review: ProductionReviewPane(model: model)
                    case .reports: ProductionReportPane(model: model)
                    case .workers: workersPane
                    }
                }
            }.workspacePage()
        }
        .id(pane)
        .background(WorkspaceStyle.canvas).navigationTitle("Batch runs")
        .task {
            await model.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                if model.runningJobID != nil { await model.refresh() }
            }
        }
        .sheet(isPresented: Binding(get: { importURL != nil }, set: { if !$0 { importURL = nil } })) {
            if let url = importURL { ProductionImportSheet(model: model, file: url) }
        }
        .sheet(isPresented: $creatingJob) { ProductionJobSheet(model: model, store: store) }
        .alert("Batch runs", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("Cancel this batch?", isPresented: $cancelling) {
            Button("Keep running", role: .cancel) {}
            Button("Cancel batch", role: .destructive) { model.setControl(cancelled: true) }
        } message: { Text("Completed evidence is retained. Cancellation is permanent for this job; create a new job to run again.") }
        .onChange(of: model.selectedJobID) { _,_ in approvedDisclosure = false }
    }
    private var datasetPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("Import examples…", systemImage: "square.and.arrow.down") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                    panel.title = "Import JSONL examples"
                    if panel.runModal() == .OK { importURL = panel.url }
                }.buttonStyle(.borderedProminent)
                Button("Freeze current suite", systemImage: "snowflake") { model.snapshotDataset(store: store) }.buttonStyle(.bordered)
            }
            Text("Imports accept JSONL with id, sourceID, prompt, expected, partition and metadata. Original outputs and feedback can be included. A source stays in one partition to prevent held-out leakage.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                WorkspacePanelHeader("Versioned datasets", count: model.datasets.count)
                WorkspaceSearchField(prompt: "Find a dataset", text: $search, identifier: "Search production datasets").padding(.horizontal,18).padding(.bottom,12)
                Divider()
                if model.datasets.isEmpty { WorkspaceEmptyState(symbol: "tray", title: "No datasets yet", detail: "Import representative examples or freeze the current suite to begin.") }
                ForEach(model.datasets.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { dataset in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text(dataset.name).font(.headline); Text(dataset.version).foregroundStyle(.secondary); Spacer(); Text("\(dataset.count) examples").font(.callout) }
                        Text("\(dataset.sampling.rawValue.capitalized) · \(dataset.partitionCounts.map { "\($0.value) \($0.key)" }.sorted().joined(separator: " · "))").font(.caption).foregroundStyle(.secondary)
                        Text("Revision \(dataset.revision.prefix(16))").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            Button("New batch") { creatingJob = true }.buttonStyle(.bordered)
                            Button("Review captured outputs") { model.createCaptured(dataset); pane = .jobs }.buttonStyle(.bordered)
                        }
                    }.padding(18)
                    Divider()
                }
            }.workspaceSurface()
        }
    }
    private var jobsPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("New batch", systemImage: "plus") { creatingJob = true }.buttonStyle(.borderedProminent).disabled(model.datasets.isEmpty)
                if let id = model.selectedJobID {
                    Button("Review") { pane = .review }.buttonStyle(.bordered)
                    Button("Report") { pane = .reports }.buttonStyle(.bordered)
                    Text(String(id.uuidString.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                WorkspacePanelHeader("Saved batches", count: model.jobs.count)
                if model.jobs.isEmpty { WorkspaceEmptyState(symbol: "play.rectangle", title: "No batches yet", detail: "Create a batch from a frozen dataset. Completed results survive pauses and worker restarts.") }
                ForEach(model.jobs) { job in
                    Button { model.select(job.id) } label: {
                        HStack(spacing: 12) {
                            WorkspaceIcon(symbol: job.id == model.selectedJobID ? "checkmark.circle.fill" : "play.rectangle", size: 22)
                            VStack(alignment: .leading, spacing: 3) { Text(job.name).font(.callout.weight(.semibold)); Text("\(job.plannedCount) responses · \(job.configuration.targets.count) targets · \(job.configuration.repetitions) trials").font(.caption).foregroundStyle(.secondary) }
                            Spacer(); Text(job.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        }.padding(18).contentShape(.rect)
                    }.buttonStyle(.plain)
                    Divider()
                }
            }.workspaceSurface()
            if let job = model.selectedJob {
                VStack(alignment: .leading, spacing: 14) {
                    Text(job.name).font(.headline)
                    if let report = model.report { ProgressView(value: Double(report.completed), total: Double(report.planned)); Text("\(report.completed) of \(report.planned) saved · \(model.runningJobID == job.id ? "running on this Mac" : report.phase)").font(.callout).foregroundStyle(.secondary) }
                    Text("Execution and scoring are frozen for this batch. Changes to the suite apply to new batches.").font(.callout).foregroundStyle(.secondary)
                    if let context = try? ProductionCodec.decode(NativeProductionContext.self, job.configuration.executionContext), context.suite.judgeConfiguration.usesExternalConnection {
                        Toggle("I approve sending this dataset's prompts, outputs and reference answers to the configured external judge", isOn: $approvedDisclosure)
                    }
                    if job.configuration.replaySafety == .sideEffects { Text("This batch can call app tools or a custom service. Interrupted actions need verified reconciliation before retrying.").font(.callout).foregroundStyle(.secondary) }
                    HStack {
                        Button(model.report?.phase == "paused" ? "Resume on this Mac" : "Run on this Mac", systemImage: "play.fill") {
                            model.setControl(paused: false) { model.run(store: store, externalDisclosureApproved: approvedDisclosure) }
                        }.buttonStyle(.borderedProminent).disabled(model.runningJobID != nil || model.report?.phase == "cancelled" || model.report?.phase == "completed")
                        Button("Pause", systemImage: "pause") { model.setControl(paused: true) }.buttonStyle(.bordered).disabled(model.report?.phase == "completed" || model.report?.phase == "cancelled")
                        Button("Cancel…", role: .destructive) { cancelling = true }.buttonStyle(.bordered).disabled(model.report?.phase == "cancelled")
                        Button("Repeat batch") { model.duplicateJob() }.buttonStyle(.bordered)
                        Button("Export evidence…") { model.export() }.buttonStyle(.bordered)
                    }
                }.padding(18).workspaceSurface()
            }
        }
    }
    private var workersPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Workers report their OS, hardware, locale and model. Target filters keep mismatched workers from claiming examples. These labels are provenance supplied by trusted workers; they are not hardware attestation.").font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                WorkspacePanelHeader("Registered workers", count: model.workers.count)
                if model.workers.isEmpty { WorkspaceEmptyState(symbol: "desktopcomputer", title: "No workers yet", detail: "Run a batch on this Mac or start an unattended CLI worker on an eligible Apple device.") }
                ForEach(model.workers) { worker in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(worker.name).font(.headline)
                        Text("\(worker.platform) · \(worker.operatingSystem) · \(worker.hardware)").font(.callout)
                        Text("\(worker.locale) · \(worker.model) · Last seen \(worker.lastSeen.formatted())").font(.caption).foregroundStyle(.secondary)
                    }.padding(18); Divider()
                }
            }.workspaceSurface()
            VStack(alignment: .leading, spacing: 14) {
                Text("Scheduled runs").font(.headline)
                Text("An unattended worker must be running for due jobs to launch. Schedules create fresh evidence; they do not alter the template batch.").font(.callout).foregroundStyle(.secondary)
                if let id = model.selectedJobID {
                    HStack { Text("Every"); TextField("Hours", value: $scheduleHours, format: .number).frame(width: 70); Text("hours for"); Stepper("\(scheduleRuns) runs", value: $scheduleRuns, in: 1...1_000) }
                    Button("Schedule selected batch") {
                        let hours = scheduleHours, count = scheduleRuns
                        model.perform { try $0.saveSchedule(.init(templateJobID: id, intervalSeconds: hours*3600, nextRun: Date().addingTimeInterval(hours*3600), remainingRuns: count)) }
                    }.buttonStyle(.bordered)
                } else { Text("Select a batch in Jobs to schedule it.").foregroundStyle(.secondary) }
                ForEach(model.schedules) { schedule in
                    HStack {
                        Text("Every \(Int(schedule.intervalSeconds/60)) min · \(schedule.remainingRuns) remaining").font(.callout)
                        Spacer()
                        Button(schedule.paused ? "Resume schedule" : "Pause schedule") {
                            var updated = schedule; updated.paused.toggle(); let value = updated
                            model.perform { try $0.saveSchedule(value) }
                        }.buttonStyle(.bordered)
                    }
                }
            }.padding(18).workspaceSurface()
            Text("For CI and additional devices, use intents-evals worker with an explicit target and trusted executable. The production eval guide documents the request/response protocol, polling and exit codes.").font(.callout).foregroundStyle(.secondary)
        }
    }
}
