import SwiftUI

/// Shows the dataset provenance and partition details without crowding the dataset list.
struct ProductionDatasetDetailsSheet: View {
    let dataset: ProductionDataset
    @Environment(\.dismiss) private var dismiss
    /// Presents partition counts in a predictable order for both sighted and VoiceOver users.
    private var partitionSummary: String {
        dataset.partitionCounts.map { "\($0.value) \($0.key)" }.sorted().joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(dataset.name).font(.title2.weight(.semibold))
            Form {
                LabeledContent("Version", value: dataset.version)
                    .accessibilityElement(children: .combine).accessibilityLabel("Version").accessibilityValue(dataset.version)
                LabeledContent("Sampling", value: dataset.sampling.rawValue.capitalized)
                    .accessibilityElement(children: .combine).accessibilityLabel("Sampling").accessibilityValue(dataset.sampling.rawValue.capitalized)
                LabeledContent("Partitions", value: partitionSummary)
                    .accessibilityElement(children: .combine).accessibilityLabel("Partitions").accessibilityValue(partitionSummary)
                LabeledContent("Revision") {
                    Text(dataset.revision).font(.caption.monospaced()).textSelection(.enabled)
                }
                .accessibilityElement(children: .combine).accessibilityLabel("Revision").accessibilityValue(dataset.revision)
            }.formStyle(.grouped)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 560, height: 320)
    }
}

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
    var initialDatasetRevision: String? = nil
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
    @State private var showsAdvanced = false
    @State private var error: String?
    /// Mirrors the stored batch limits so invalid hidden values cannot dismiss the sheet.
    private var validTimeout: Bool { timeout.isFinite && (0.1...3_600).contains(timeout) }
    /// Validates the hours field against the stored one-second to thirty-day limit.
    private var validBudget: Bool { budget.isFinite && (1...2_592_000).contains(budget * 3_600) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New batch").font(.title2.weight(.semibold))
            Text("Uses the current suite's model, instructions, features and scoring. Examples come from the frozen dataset.").font(.callout).foregroundStyle(.secondary)
            Form {
                Section("Batch") {
                    TextField("Name", text: $name)
                        .accessibilityLabel("Name")
                        .accessibilityIdentifier("Batch name")
                    Picker("Dataset", selection: $dataset) { ForEach(model.datasets) { Text("\($0.name) · \($0.version) · \($0.count)").tag($0.revision) } }
                        .accessibilityLabel("Dataset")
                        .accessibilityIdentifier("Batch dataset")
                    Stepper("\(repetitions) \(repetitions == 1 ? "trial" : "trials") per example and target", value: $repetitions, in: 1...20)
                    TextField("Minimum pass rate (%)", value: $passRate, format: .number)
                        .accessibilityLabel("Minimum pass rate (%)")
                        .accessibilityIdentifier("Batch minimum pass rate")
                }
                Section {
                    Button { showsAdvanced.toggle() } label: {
                        Label("Advanced options", systemImage: showsAdvanced ? "chevron.down" : "chevron.right")
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("Batch advanced options")
                    .accessibilityValue(showsAdvanced ? "Expanded" : "Collapsed")
                }
                if showsAdvanced {
                    Section("Limits and baseline") {
                        TextField("Request timeout (seconds)", value: $timeout, format: .number)
                            .accessibilityLabel("Request timeout (seconds)")
                            .accessibilityIdentifier("Batch request timeout")
                        TextField("Job time budget (hours)", value: $budget, format: .number)
                            .accessibilityLabel("Job time budget (hours)")
                            .accessibilityIdentifier("Batch time budget")
                        Picker("Baseline", selection: $baseline) {
                            Text("None").tag(Optional<UUID>.none)
                            ForEach(model.jobs.filter { $0.datasetRevision == dataset && $0.configuration.repetitions == repetitions }) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .accessibilityLabel("Baseline")
                    }
                    Section("Apple device matrix") {
                        Text("Leave filters empty to accept any eligible worker. OS and locale filters must exactly match a registered worker. Additional devices need their own trusted worker.").font(.caption).foregroundStyle(.secondary)
                        TextField("OS filter (optional)", text: $os)
                            .accessibilityLabel("OS filter (optional)")
                            .accessibilityIdentifier("Batch OS filter")
                        TextField("Locale filter (optional)", text: $locale)
                            .accessibilityLabel("Locale filter (optional)")
                        TextField("Second locale (optional)", text: $secondLocale)
                            .accessibilityLabel("Second locale (optional)")
                    }
                    Section("Required cohort") {
                        TextField("Metadata key (optional)", text: $cohortKey)
                            .accessibilityLabel("Metadata key (optional)")
                        TextField("Metadata value", text: $cohortValue)
                            .accessibilityLabel("Metadata value")
                        TextField("Cohort minimum pass rate (%)", value: $cohortPassRate, format: .number)
                            .accessibilityLabel("Cohort minimum pass rate (%)")
                            .accessibilityIdentifier("Batch cohort minimum pass rate")
                    }
                }
            }.formStyle(.grouped).textFieldStyle(.roundedBorder)
            if !(0...100).contains(cohortPassRate) {
                Text("The cohort minimum pass rate must be between 0 and 100. Open Advanced options to change it.")
                    .font(.callout).foregroundStyle(.red)
            }
            if !validTimeout {
                Text("Request timeout must be between 0.1 and 3,600 seconds. Open Advanced options to change it.")
                    .font(.callout).foregroundStyle(.red)
            }
            if !validBudget {
                Text("Job time budget must be between 1 second and 720 hours. Open Advanced options to change it.")
                    .font(.callout).foregroundStyle(.red)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Create batch") {
                do {
                    var targets = [ProductionTarget(operatingSystem: os.isEmpty ? nil : os, locale: locale.isEmpty ? nil : locale)]
                    if !secondLocale.isEmpty { targets.append(.init(operatingSystem: os.isEmpty ? nil : os, locale: secondLocale)) }
                    try model.createJob(store: store, dataset: dataset, name: name, repetitions: repetitions, passRate: passRate, timeout: timeout, budgetHours: budget,
                                        baseline: baseline, targets: targets, requiredCohortKey: cohortKey, requiredCohortValue: cohortValue, cohortPassRate: cohortPassRate)
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }.buttonStyle(.borderedProminent).disabled(name.isEmpty || dataset.isEmpty || !(0...100).contains(passRate) || !(0...100).contains(cohortPassRate) || !validTimeout || !validBudget) }
        }.padding(24).frame(width: 600, height: showsAdvanced ? 680 : 520).onAppear {
            dataset = model.datasets.first(where: { $0.revision == initialDatasetRevision })?.revision
                ?? model.datasets.first?.revision ?? ""
            name = store.draftSuite.name + " · batch"
        }
    }
}
