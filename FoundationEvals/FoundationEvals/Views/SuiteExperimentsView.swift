import SwiftUI

struct SuiteExperimentsView: View {
    @Bindable var store: EvaluationStore
    @State private var isCreatingExperiment = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Instruction experiments").font(.title3.weight(.semibold))
                    Text("Compare a proposed instruction change against the same cases, model and scoring.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("New experiment", systemImage: "plus") { isCreatingExperiment = true }
                    .disabled(store.isRunning || store.isReassessing || store.isProcessingFiles)
            }
            if store.suiteLocalState.experiments.isEmpty {
                Text("An experiment keeps both instruction versions and the results together, so you can review the difference before adopting a change.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
            } else {
                ForEach(store.suiteLocalState.experiments.reversed()) { experiment in
                    ExperimentRow(store: store, experiment: experiment)
                }
            }
        }
        .sheet(isPresented: $isCreatingExperiment) { InstructionExperimentEditor(store: store) }
    }
}

private struct InstructionExperimentEditor: View {
    @Bindable var store: EvaluationStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Instruction comparison"
    @State private var candidate = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Compare an instruction change").font(.title2.weight(.semibold))
            Text("The cases, model and scoring are saved with this experiment. Creating it does not start a run.")
                .foregroundStyle(.secondary)
            TextField("Experiment name", text: $name)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current instructions").font(.headline)
                    ScrollView {
                        Text(store.draftSuite.instructions.isEmpty ? "No instructions" : store.draftSuite.instructions)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Proposed instructions").font(.headline)
                    TextEditor(text: $candidate)
                        .padding(6)
                        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator) }
                        .accessibilityLabel("Proposed instructions")
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create experiment") {
                    do {
                        _ = try store.createInstructionExperiment(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines), candidateInstructions: candidate
                        )
                        dismiss()
                    } catch { errorMessage = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || candidate == store.draftSuite.instructions)
            }
        }
        .padding(24)
        .frame(width: 720, height: 480)
        .onAppear { candidate = store.draftSuite.instructions }
    }
}

private struct ExperimentRow: View {
    @Bindable var store: EvaluationStore
    let experiment: EvaluationExperiment

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(experiment.name).font(.headline)
                Spacer()
                if experiment.runIDs.count != 2 {
                    Button("Run") { store.runExperiment(id: experiment.id) }
                        .disabled(store.isRunning || store.isReassessing || store.isProcessingFiles)
                } else if let decision = experiment.decision {
                    Text(decision.title).font(.caption).foregroundStyle(.secondary)
                } else {
                    Menu("Record decision") {
                        ForEach(EvaluationExperimentDecision.allCases, id: \.self) { decision in
                            Button(decision.title) {
                                do { try store.decideExperiment(id: experiment.id, decision: decision) }
                                catch { store.notice = error.localizedDescription }
                            }
                        }
                    }
                }
            }
            Text("\(experiment.executionOrder.count) samples across current and proposed instructions")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(experiment.candidate.instructions)
                .font(.callout)
                .lineLimit(3)
            if experiment.runIDs.count == 2,
               let current = store.run(with: experiment.runIDs[0]),
               let candidate = store.run(with: experiment.runIDs[1]) {
                let summary = EvaluationExperimentAnalyzer.summarize(current: current, candidate: candidate)
                Text("\(summary.improvedCaseIDs.count) improved · \(summary.regressedCaseIDs.count) regressed · \(summary.distinctCaseCoverage) distinct cases · \(summary.explanation)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }
}

private extension EvaluationExperimentDecision {
    var title: String {
        switch self {
        case .keepCurrent: "Keep current"
        case .adoptCandidate: "Adopt candidate"
        case .collectMoreEvidence: "Collect more evidence"
        case .inconclusive: "Inconclusive"
        }
    }
}
