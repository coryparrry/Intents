import SwiftUI

struct ProductionImportSheet: View {
    let model: ProductionWorkspaceStore
    let file: URL
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var version = "v1"
    @State private var sampling: ProductionSampling = .curated
    @State private var production = false
    @State private var confirmed = false
    @State private var preview: [ProductionExample] = []
    @State private var previewError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Import examples").font(.title2.weight(.semibold))
            Text(file.lastPathComponent).font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Preview · first \(preview.count) examples").font(.subheadline.weight(.medium))
                if let previewError { Text(previewError).font(.callout).foregroundStyle(.red) }
                ForEach(preview) { example in
                    Text("\(example.id) · \(example.partition.rawValue) · \(example.prompt.prefix(120))").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text("All remaining rows are validated when importing.").font(.caption).foregroundStyle(.secondary)
            }.padding(14).workspaceSurface()
            Form {
                TextField("Dataset name", text: $name)
                TextField("Version", text: $version)
                Picker("Sampling", selection: $sampling) { ForEach(ProductionSampling.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                Toggle("Contains production data", isOn: $production)
                if production {
                    Text("Remove personal information, credentials and sensitive content before import. Nothing is captured or uploaded automatically.").font(.callout).foregroundStyle(.secondary)
                    Toggle("I have reviewed and redacted this file", isOn: $confirmed)
                }
            }.formStyle(.grouped)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Import") {
                model.importDataset(file: file, name: name, version: version, sampling: sampling, productionData: production, confirmed: confirmed); dismiss()
            }.buttonStyle(.borderedProminent).disabled(preview.isEmpty || previewError != nil || name.trimmingCharacters(in: .whitespaces).isEmpty || version.isEmpty || production && !confirmed) }
        }.padding(24).frame(width: 540).task {
            name = file.deletingPathExtension().lastPathComponent
            do { preview = try await Task.detached { try ProductionStorage.previewExamples(from: file) }.value }
            catch { previewError = error.localizedDescription }
        }
    }
}

struct ProductionJobSheet: View {
    let model: ProductionWorkspaceStore
    let store: EvaluationStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var dataset = ""
    @State private var repetitions = 1
    @State private var passRate = 100.0
    @State private var timeout = 120.0
    @State private var budget = 24.0
    @State private var baseline: UUID?
    @State private var locale = ""
    @State private var os = ""
    @State private var secondLocale = ""
    @State private var cohortKey = ""
    @State private var cohortValue = ""
    @State private var cohortPassRate = 100.0
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New batch").font(.title2.weight(.semibold))
            Text("Uses the current suite's model, instructions, features and scoring. Examples come from the frozen dataset.").font(.callout).foregroundStyle(.secondary)
            Form {
                Section("Batch") {
                    TextField("Name", text: $name)
                    Picker("Dataset", selection: $dataset) { ForEach(model.datasets) { Text("\($0.name) · \($0.version) · \($0.count)").tag($0.revision) } }
                    Stepper("\(repetitions) trials per example and target", value: $repetitions, in: 1...20)
                    TextField("Minimum pass rate (%)", value: $passRate, format: .number)
                    TextField("Request timeout (seconds)", value: $timeout, format: .number)
                    TextField("Job time budget (hours)", value: $budget, format: .number)
                    Picker("Baseline", selection: $baseline) {
                        Text("None").tag(Optional<UUID>.none)
                        ForEach(model.jobs.filter { $0.datasetRevision == dataset && $0.configuration.repetitions == repetitions }) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Section("Apple device matrix") {
                    Text("Leave filters empty to accept any eligible worker. OS and locale filters must exactly match a registered worker. Additional devices need their own trusted worker.").font(.caption).foregroundStyle(.secondary)
                    TextField("OS filter (optional)", text: $os)
                    TextField("Locale filter (optional)", text: $locale)
                    TextField("Second locale (optional)", text: $secondLocale)
                }
                Section("Required cohort") {
                    TextField("Metadata key (optional)", text: $cohortKey)
                    TextField("Metadata value", text: $cohortValue)
                    TextField("Cohort minimum pass rate (%)", value: $cohortPassRate, format: .number)
                }
            }.formStyle(.grouped)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Create batch") {
                do {
                    var targets = [ProductionTarget(operatingSystem: os.isEmpty ? nil : os, locale: locale.isEmpty ? nil : locale)]
                    if !secondLocale.isEmpty { targets.append(.init(operatingSystem: os.isEmpty ? nil : os, locale: secondLocale)) }
                    try model.createJob(store: store, dataset: dataset, name: name, repetitions: repetitions, passRate: passRate, timeout: timeout, budgetHours: budget,
                                        baseline: baseline, targets: targets, requiredCohortKey: cohortKey, requiredCohortValue: cohortValue, cohortPassRate: cohortPassRate)
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }.buttonStyle(.borderedProminent).disabled(name.isEmpty || dataset.isEmpty || !(0...100).contains(passRate) || !(0...100).contains(cohortPassRate)) }
        }.padding(24).frame(width: 600, height: 680).onAppear { dataset = model.datasets.first?.revision ?? ""; name = store.draftSuite.name + " · batch" }
    }
}
