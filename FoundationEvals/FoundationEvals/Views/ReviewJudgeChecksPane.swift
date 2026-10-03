import SwiftUI

struct ReviewJudgeChecksPane: View {
    @Bindable var store: EvaluationStore
    @State private var connectionID: UUID?
    @State private var error: String?
    private var examples: [EvaluationReviewedJudgeExample] { store.suiteLocalState.reviewedJudgeExamples }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Keep examples used to refine your judge in Development. Reserve Held-out test for examples you have not used to tune its rubric. Moving an example moves every repetition and run of the same case.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Picker("Judge connection", selection: $connectionID) {
                        Text("Choose a judge").tag(Optional<UUID>.none)
                        ForEach(store.judgeConnections) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Button("Run judge checks") { if let connectionID { store.runJudgeChecks(connectionID: connectionID) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(connectionID == nil || examples.isEmpty || store.isRunning || store.isReassessing)
                    if store.isReassessing { ProgressView().controlSize(.small) }
                }
                Text("Checks replay recorded outputs using the existing evidence-transfer approval. They do not run the app feature again. Results are grouped by scoring contract; error examples remain visible.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(18).workspaceSurface()
            if let report = store.latestJudgeCheck {
                Text("Latest check · \(store.judgeConnections.first(where: { $0.id == report.connectionID })?.name ?? "Saved judge")")
                    .font(.headline)
                ForEach(report.calibrationGroups) { group in
                    ReviewCalibrationSummary(group: group)
                }
                let errors = report.results.filter { $0.errorMessage != nil }
                if !errors.isEmpty {
                    DisclosureGroup("Unavailable checks · \(errors.count)") {
                        ForEach(errors) { result in
                            let source = store.reviewSamples.first { $0.run.id == result.example.sourceRunID && $0.sample.id == result.example.sampleID }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(source?.sample.caseName ?? "Source unavailable") · \((result.example.partition ?? .development).title)")
                                    .font(.callout.weight(.medium))
                                Text("Run \(result.example.sourceRunID.uuidString.prefix(8)) · Sample \(result.example.sampleID.uuidString.prefix(8))")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(result.errorMessage ?? "Unavailable").font(.callout).textSelection(.enabled)
                                if source != nil {
                                    Button("Open report") { store.selection = .run(result.example.sourceRunID) }.buttonStyle(.borderless)
                                }
                            }.padding(.vertical, 8)
                        }
                    }.padding(18).workspaceSurface()
                }
            }
            if examples.isEmpty {
                WorkspaceEmptyState(symbol: "checkmark.seal", title: "No reviewed judge examples",
                                    detail: "Save a human review in Samples, then use it as a judge check. Existing judgment corrections can also supply examples.")
                    .workspaceSurface()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    WorkspacePanelHeader("Reviewed examples", count: examples.count)
                    ForEach(examples) { example in
                        let sample = store.reviewSamples.first { $0.run.id == example.sourceRunID && $0.sample.id == example.sampleID }
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(sample?.sample.caseName ?? "Source unavailable").font(.callout.weight(.medium))
                                Text("Human: \(example.expectedStatus.rawValue) · \(example.reason)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Picker("Example group", selection: Binding(
                                get: { example.partition ?? .development },
                                set: { partition in
                                    do { try store.setJudgeCheckPartition(exampleID: example.id, partition: partition) }
                                    catch { self.error = error.localizedDescription }
                                }
                            )) { ForEach(EvaluationJudgeCheckPartition.allCases) { Text($0.title).tag($0) } }
                                .labelsHidden().fixedSize().disabled(store.isReassessing)
                        }.padding(.horizontal, 18).padding(.vertical, 12)
                        Divider()
                    }
                }.workspaceSurface()
            }
        }
        .onAppear { connectionID = store.draftSuite.judgeConfiguration.connectionID }
        .alert("Could not change judge group", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}

private struct ReviewCalibrationSummary: View {
    let group: EvaluationJudgeCalibrationGroup
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(group.partition.title).font(.headline)
                Spacer()
                Text(group.contractDigest == "unknown" ? "Contract unavailable" : "Contract \(group.contractDigest.prefix(8))")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow { Text("Correctly accepted successes"); Text(group.correctPasses.formatted()) }
                GridRow { Text("Incorrectly rejected successes"); Text("\(group.falseFailures) / \(group.humanPassCount) human successes") }
                GridRow { Text("Incorrectly accepted failures"); Text("\(group.falsePasses) / \(group.humanFailCount) human failures") }
                GridRow { Text("Correctly rejected failures"); Text(group.correctFailures.formatted()) }
                GridRow { Text("Unavailable or errors"); Text(group.unavailable.formatted()) }
            }.font(.callout)
            Text("False-pass rate: \(rate(group.falsePassRate)) · False-failure rate: \(rate(group.falseFailureRate))")
                .font(.callout.weight(.medium))
            if !group.hasBothClasses {
                Label("Include both human successes and failures to assess this judge. Missing classes have no estimated rate.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Counts are examples, not independent cases. Small held-out sets provide limited evidence; these checks do not certify a release.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18).workspaceSurface()
    }
    private func rate(_ value: Double?) -> String {
        value.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "Unavailable"
    }
}
