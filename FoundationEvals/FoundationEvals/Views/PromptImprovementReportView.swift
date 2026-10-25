import SwiftUI

struct PromptImprovementReportView: View {
    let report: EvaluationPromptImprovement
    let isStale: Bool
    let inspect: (EvaluationRun) -> Void
    @State private var showsDetails = false
    @State private var showsOtherSuggestions = false

    private var presentation: PromptImprovementPresentation { .init(report: report, isStale: isStale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            WorkspaceNotice(noticeKind,
                            title: presentation.title, message: presentation.detail)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(presentation.title). \(presentation.detail)")
                .accessibilityIdentifier("Instruction comparison outcome")
            if report.developmentBaseline != nil {
                EditorSection("Results", description: "Passed responses out of all planned responses. Each example may be repeated by your suite’s settings.") {
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                        GridRow { Text(""); Text("Current"); Text("Suggested") }.font(.callout.weight(.semibold))
                        GridRow {
                            Text("Practice").foregroundStyle(.secondary)
                            score(report.developmentBaseline)
                            if report.status == .noImprovement { Text("None selected").foregroundStyle(.secondary) }
                            else { score(report.selectedCandidate?.developmentRun) }
                        }
                        Divider().gridCellColumns(3)
                        GridRow {
                            Text("Final check").foregroundStyle(.secondary)
                            score(report.heldOutBaseline)
                            score(report.heldOutCandidate)
                        }
                    }
                    .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    if report.status == .noImprovement {
                        Text("Neither suggestion beat the current instructions. See both suggestions below.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if report.status == .completed {
                        Text("A small comparison is a useful signal, not a guarantee. Try more varied examples before relying on a change.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let candidate = report.selectedCandidate {
                EditorSection("Review the instructions", description: "Only these shared instructions will change. Your cases and settings stay the same.") {
                    HStack(alignment: .top, spacing: 16) {
                        instructions("Current", text: report.source.instructions)
                        instructions("Suggested", text: candidate.instructions)
                    }.fixedSize(horizontal: false, vertical: true)
                }
            }
            if !report.candidates.isEmpty {
                DisclosureGroup("All suggestions", isExpanded: $showsOtherSuggestions) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(report.candidates.enumerated()), id: \.element.id) { index, candidate in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Suggestion \(index + 1)").font(.callout.weight(.semibold))
                                    if candidate.id == report.selectedCandidateID { WorkspacePill("Best in practice", symbol: "checkmark", color: .accentColor) }
                                    Spacer()
                                    Text("Practice: \(PromptImprovementPresentation.scoreSummary(candidate.developmentRun))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text(candidate.instructions).textSelection(.enabled).font(.callout)
                            }
                            if index < report.candidates.count - 1 { Divider() }
                        }
                    }.padding(.top, 12)
                }.padding(22).workspaceSurface()
            }
            DisclosureGroup("Comparison details", isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(report.createdAt.formatted(date: .long, time: .shortened)).foregroundStyle(.secondary)
                    Text("\(report.developmentSuite.cases.count) practice · \(report.heldOutCaseIDs.count) final check · \(report.source.repetitions) \(report.source.repetitions == 1 ? "response per example" : "responses per example")")
                    Text(report.message).textSelection(.enabled)
                    if report.selectedCandidate == nil { instructions("Original instructions", text: report.source.instructions) }
                    if let run = report.developmentBaseline { evidence("Current · Practice", run: run) }
                    ForEach(Array(report.candidates.enumerated()), id: \.element.id) { index, candidate in
                        if let run = candidate.developmentRun { evidence("Suggestion \(index + 1) · Practice", run: run) }
                    }
                    if let run = report.heldOutBaseline { evidence("Current · Final check", run: run) }
                    if let run = report.heldOutCandidate { evidence("Suggested · Final check", run: run) }
                }.font(.callout).padding(.top, 12)
            }.padding(22).workspaceSurface()
        }
    }

    private func instructions(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            Text(text.isEmpty ? "No shared instructions" : text).font(.callout).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(14).workspaceInset().accessibilityElement(children: .combine)
    }

    private var noticeKind: WorkspaceNotice<EmptyView>.Kind {
        if report.appliedAt != nil || (report.canApply && !isStale) { return .success }
        if report.status == .failed || report.status == .completed || report.status == .running { return .warning }
        return .info
    }

    private func score(_ run: EvaluationRun?) -> some View {
        Text(PromptImprovementPresentation.scoreSummary(run)).monospacedDigit()
            .accessibilityLabel(run.map { PromptImprovementPresentation.scoreSummary($0) == "Incomplete"
                ? "Incomplete" : "\($0.passedCount) of \($0.plannedResultCount) passed" } ?? "Not run")
    }

    private func evidence(_ title: String, run: EvaluationRun) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button("View responses") { inspect(run) }.accessibilityLabel("View responses: \(title)")
        }
    }
}
