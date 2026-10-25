import SwiftUI

struct PromptImprovementButton: View {
    @Bindable var store: EvaluationStore
    @State private var isPresented = false

    var body: some View {
        Button("Improve instructions", systemImage: "sparkles") { isPresented = true }
            .accessibilityIdentifier("Improve instructions")
            .sheet(isPresented: $isPresented) { PromptImprovementView(store: store) }
    }
}

struct PromptImprovementView: View {
    @Bindable var store: EvaluationStore
    @Environment(\.dismiss) private var dismiss
    @State private var heldOutCaseIDs: Set<UUID> = []
    @State private var errorMessage: String?
    @State private var hasInitialized = false

    private var issue: String? {
        EvaluationPromptImprovementRules.validationIssue(suite: store.draftSuite, heldOutCaseIDs: heldOutCaseIDs)
    }

    private var budget: Int {
        guard issue == nil else { return 0 }
        return EvaluationPromptImprovement(source: store.draftSuite, heldOutCaseIDs: heldOutCaseIDs).maximumSamples
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Improve model instructions").font(.title2.weight(.semibold))
                    Text("Generate two alternatives, compare their results, then review a change.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    setup
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
                    if store.isRunning {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(store.suiteLocalState.promptImprovements.last?.message ?? "An evaluation is running")
                            Spacer()
                            Button("Cancel run", role: .cancel) { store.cancelRun() }
                        }
                        Text("\(store.completedSamples) of at most \(store.totalSamples) samples completed")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(store.suiteLocalState.promptImprovements.reversed()) { report in
                        PromptImprovementReportView(store: store, report: report)
                    }
                }
                .padding(.trailing, 8)
            }
        }
        .padding(24)
        .frame(minWidth: 740, idealWidth: 820, minHeight: 580, idealHeight: 760)
        .onAppear {
            guard !hasInitialized else { return }
            hasInitialized = true
            heldOutCaseIDs = Set(store.draftSuite.cases.suffix(max(1, store.draftSuite.cases.count / 5)).map(\.id))
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reserve Held-out cases").font(.headline)
            Text("Unchecked cases are Development examples used to write and select alternatives. Checked cases are used only to validate the selected alternative. Use fresh Held-out cases for each new comparison.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(store.draftSuite.cases) { test in
                Toggle(isOn: Binding(
                    get: { heldOutCaseIDs.contains(test.id) },
                    set: { if $0 { heldOutCaseIDs.insert(test.id) } else { heldOutCaseIDs.remove(test.id) } }
                )) {
                    HStack {
                        Text(test.name.isEmpty ? "Untitled case" : test.name)
                        Spacer()
                        Text(heldOutCaseIDs.contains(test.id) ? "Held-out" : "Development")
                            .foregroundStyle(.secondary).font(.caption)
                    }
                }
                .toggleStyle(.checkbox)
            }
            Text("Suggestions are generated on this Mac. Comparison runs use your suite’s model, tools, references and scoring, including any approved external judge. Model and tool calls may run up to \(budget) evaluation samples plus two instruction suggestions.")
                .font(.caption).foregroundStyle(.secondary)
            if let issue { Text(issue).font(.callout).foregroundStyle(.secondary) }
            Button("Generate and compare", systemImage: "sparkles") {
                do {
                    errorMessage = nil
                    try store.startPromptImprovement(heldOutCaseIDs: heldOutCaseIDs)
                } catch { errorMessage = error.localizedDescription }
            }
            .buttonStyle(.borderedProminent)
            .disabled(issue != nil || store.isRunning || store.isReassessing || store.isProcessingFiles)
            .accessibilityIdentifier("Generate and compare instructions")
        }
        .disabled(store.isRunning)
        .padding(16)
        .workspaceInset(radius: 10)
    }
}

private struct PromptImprovementReportView: View {
    @Bindable var store: EvaluationStore
    let report: EvaluationPromptImprovement
    @State private var isExpanded = true
    @State private var errorMessage: String?

    private var isStale: Bool { store.draftSuite != report.source || store.suite != report.source }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text(report.message).font(.callout).textSelection(.enabled)
                Text("\(report.developmentSuite.cases.count) Development · \(report.heldOutCaseIDs.count) Held-out · \(report.source.repetitions) repetitions")
                    .font(.caption).foregroundStyle(.secondary)
                if report.status == .running && !store.isRunning {
                    Text("This comparison was interrupted. Its partial evidence cannot recommend a change.")
                        .foregroundStyle(.secondary)
                }
                if let baseline = report.developmentBaseline {
                    evidence("Current · Development", run: baseline)
                }
                ForEach(Array(report.candidates.enumerated()), id: \.element.id) { index, candidate in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Alternative \(index + 1)\(candidate.id == report.selectedCandidateID ? " · Selected on Development" : "")")
                            .font(.headline)
                        Text(candidate.instructions).textSelection(.enabled)
                        if let run = candidate.developmentRun { evidence("Development", run: run) }
                    }
                }
                if let baseline = report.heldOutBaseline { evidence("Current · Held-out", run: baseline) }
                if let candidate = report.heldOutCandidate { evidence("Selected alternative · Held-out", run: candidate) }
                DisclosureGroup("Original instructions") { Text(report.source.instructions).textSelection(.enabled) }
                if report.appliedAt != nil {
                    Label("Instructions applied", systemImage: "checkmark.circle")
                } else if report.canApply {
                    if isStale { Text("The suite has changed. This saved candidate cannot overwrite your edits.").foregroundStyle(.secondary) }
                    Button("Apply validated instructions") {
                        do { try store.applyPromptImprovement(id: report.id) }
                        catch { errorMessage = error.localizedDescription }
                    }
                    .disabled(isStale || store.isRunning || store.isReassessing || store.isProcessingFiles)
                    .accessibilityIdentifier("Apply validated instructions")
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .padding(.top, 10)
        } label: {
            Text("Comparison · \(report.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.headline)
        }
        .padding(16)
        .workspaceInset(radius: 10)
    }

    private func evidence(_ title: String, run: EvaluationRun) -> some View {
        HStack {
            let rate = run.passRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "Unscored"
            Text("\(title): \(run.passedCount)/\(run.plannedResultCount) passed (\(rate))")
            Spacer()
            Button("Inspect run") {
                store.selection = .run(run.id)
            }
            .disabled(store.isRunning)
        }
        .font(.caption)
    }
}
