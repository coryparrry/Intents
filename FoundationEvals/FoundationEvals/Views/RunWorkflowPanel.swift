import SwiftUI

struct RunWorkflowPanel: View {
    @Bindable var store: EvaluationStore
    let run: EvaluationRun
    @State private var correctionSample: EvaluationSampleAssessment?
    @State private var reportText: String?

    private var selectedAssessment: EvaluationAssessment? {
        guard let selected = run.selectedAssessmentID else { return run.assessments?.last }
        return run.assessments?.first { $0.id == selected }
    }

    private var isApprovedAssessment: Bool {
        store.activeBaselineApproval?.runID == run.id
            && store.activeBaselineApproval?.assessmentID == selectedAssessment?.id
    }

    var body: some View {
        GroupBox("Review and approval") {
            VStack(alignment: .leading, spacing: 12) {
                if let assessments = run.assessments, !assessments.isEmpty {
                    Picker("Selected assessment", selection: Binding(
                        get: { run.selectedAssessmentID ?? assessments[assessments.count - 1].id },
                        set: { id in
                            do { try store.selectAssessment(runID: run.id, assessmentID: id) }
                            catch { store.notice = error.localizedDescription }
                        }
                    )) {
                        ForEach(assessments) { assessment in
                            Text("\(assessment.judge.displayName) · \(assessment.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .tag(assessment.id)
                        }
                    }

                    if let assessment = selectedAssessment {
                        DisclosureGroup("Assessment details") {
                          Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                            GridRow { Text("Origin"); Text(assessment.origin.rawValue) }
                            GridRow { Text("Prompt"); Text(assessment.promptVersion) }
                            GridRow { Text("Judge"); Text(assessment.judge.displayName) }
                            GridRow { Text("Errors"); Text(assessment.errorCount.formatted()) }
                            GridRow {
                                Text("Judge cost")
                                Text(assessment.cost.usd.map { $0.formatted(.currency(code: "USD")) }
                                     ?? assessment.cost.explanation)
                            }
                        }
                          .font(.callout)
                          .padding(.top, 8)
                        }

                        if !assessment.samples.isEmpty {
                            Menu("Correct a judgment") {
                                ForEach(assessment.samples) { sample in
                                    let name = run.results.first { $0.id == sample.sampleID }?.caseName ?? "Saved sample"
                                    Button(name) { correctionSample = sample }
                                }
                            }
                        }
                    }
                } else {
                    Text("This run has no separately stored assessment. Legacy run scores remain unchanged.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Menu("Reassess saved responses") {
                        ForEach(store.judgeConnections) { connection in
                            Button(connection.name) { store.reassessRun(id: run.id, connectionID: connection.id) }
                        }
                    }
                    .disabled(store.judgeConnections.isEmpty || store.isReassessing)
                    if store.isReassessing { ProgressView().controlSize(.small) }

                    Button("Approve as baseline", systemImage: "checkmark.seal") {
                        do {
                            try store.approveBaseline(runID: run.id, assessmentID: selectedAssessment?.id)
                        } catch { store.notice = error.localizedDescription }
                    }
                    .disabled(isApprovedAssessment)

                    Button("Release report", systemImage: "shippingbox.and.arrow.backward") {
                        reportText = EvaluationReleaseCheckEvaluator.markdown(store.releaseCheckReport(runID: run.id))
                    }
                    Spacer()
                    if isApprovedAssessment {
                        Label("Approved baseline", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                }
                .disabled(store.isRunning || store.isReassessing || store.isProcessingFiles)

                if let reportText {
                    Text(reportText)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(10)
                        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 7))
                }
            }
            .padding(8)
        }
        .sheet(item: $correctionSample) { sample in
            JudgmentCorrectionView(store: store, run: run, assessment: selectedAssessment, sample: sample)
        }
    }
}

private struct JudgmentCorrectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: EvaluationStore
    let run: EvaluationRun
    let assessment: EvaluationAssessment?
    let sample: EvaluationSampleAssessment
    @State private var correctedStatus = EvaluationResultStatus.failed
    @State private var correctedScore: Int? = 2
    @State private var reason = ""
    @State private var reviewer = ""
    @State private var collectAsCheck = true
    @State private var errorMessage: String?

    private var canCollectAsCheck: Bool {
        guard run.results.first(where: { $0.id == sample.sampleID })?
                .hasCompleteSubjectEvidenceForJudging == true,
              correctedStatus == .passed || correctedStatus == .failed,
              assessment?.promptVersion == EvaluationRunner.judgePromptVersion else {
            return false
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Correct judgment").font(.title2.bold())
            Text("The original \(sample.status.rawValue) judgment and score remain preserved in the run.")
                .foregroundStyle(.secondary)
            Picker("Correct status", selection: $correctedStatus) {
                Text("Passed").tag(EvaluationResultStatus.passed)
                Text("Failed").tag(EvaluationResultStatus.failed)
                Text("Unscored").tag(EvaluationResultStatus.unscored)
            }
            Picker("Correct score", selection: $correctedScore) {
                Text("None").tag(Int?.none)
                ForEach(1...4, id: \.self) { Text($0.formatted()).tag(Optional($0)) }
            }
            TextField("Reviewer (optional)", text: $reviewer)
            Text("Why is this judgment incorrect?").font(.headline)
            TextEditor(text: $reason)
                .frame(minHeight: 100)
                .padding(6)
                .overlay { RoundedRectangle(cornerRadius: 7).stroke(.separator) }
                .accessibilityLabel("Correction reason")
            Toggle("Keep as a known-good judge check", isOn: $collectAsCheck)
                .disabled(!canCollectAsCheck)
                .help(canCollectAsCheck
                    ? "Replay this complete saved response when checking a judge connection."
                    : "Only complete subject responses, passed or failed corrections, and the current judge prompt can be used as known-good judge checks.")
            if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Save correction") {
                    guard let assessment else { return }
                    do {
                        try store.markJudgmentIncorrect(
                            runID: run.id,
                            assessmentID: assessment.id,
                            sampleID: sample.sampleID,
                            correctedStatus: correctedStatus,
                            correctedScore: correctedScore,
                            reason: reason,
                            reviewer: reviewer.isEmpty ? nil : reviewer,
                            collectAsJudgeCheck: collectAsCheck
                        )
                        dismiss()
                    } catch { errorMessage = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 500, height: 480)
        .onAppear {
            correctedStatus = sample.status == .passed ? .failed : .passed
            correctedScore = correctedStatus == .passed ? 4 : 2
            if !canCollectAsCheck { collectAsCheck = false }
        }
        .onChange(of: correctedStatus) { _, _ in
            if !canCollectAsCheck { collectAsCheck = false }
        }
    }
}
