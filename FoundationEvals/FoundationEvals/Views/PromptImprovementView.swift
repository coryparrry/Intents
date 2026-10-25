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
    var configure: ((Bool) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var heldOutCaseIDs: Set<UUID> = []
    @State private var selectedReportID: UUID?
    @State private var showsHistory = false
    @State private var errorMessage: String?
    @State private var hasInitialized = false

    private var reports: [EvaluationPromptImprovement] { store.suiteLocalState.promptImprovements }
    private var report: EvaluationPromptImprovement? { reports.first { $0.id == selectedReportID } }
    private var isActive: Bool { report != nil && store.activePromptImprovementID == selectedReportID }
    private var isBusy: Bool { store.isRunning || store.isReassessing || store.isProcessingFiles }
    private var isStale: Bool { report.map { store.draftSuite != $0.source || store.suite != $0.source } ?? false }
    private var issue: String? { PromptImprovementPresentation.setupIssue(suite: store.draftSuite, heldOutCaseIDs: heldOutCaseIDs) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                WorkspaceIcon(symbol: "sparkles", size: 32).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Improve instructions").font(.title2.weight(.semibold))
                    Text(showsHistory ? "Past comparisons for this suite" : store.draftSuite.name)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if !reports.isEmpty && !showsHistory && !isActive {
                    Button("History", systemImage: "clock") { showsHistory = true; errorMessage = nil }
                }
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let errorMessage {
                        WorkspaceNotice(.failure, title: "Couldn’t complete that action", message: errorMessage)
                    }
                    if showsHistory { history }
                    else if let report {
                        if isActive { progress(report) }
                        else {
                            PromptImprovementReportView(report: report, isStale: isStale) { run in
                                dismiss()
                                store.selection = .run(run.id)
                            }.id(report.id)
                        }
                    } else {
                        PromptImprovementSetupView(suite: store.draftSuite, heldOutCaseIDs: $heldOutCaseIDs, issue: issue,
                            configure: configureAction)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.background(WorkspaceStyle.canvas)
            Divider()
            footer
        }
        .frame(width: 800, height: 680)
        .onAppear {
            guard !hasInitialized else { return }
            hasInitialized = true
            heldOutCaseIDs = Set(store.draftSuite.cases.suffix(max(1, store.draftSuite.cases.count / 5)).map(\.id))
            selectedReportID = store.activePromptImprovementID ?? reports.last?.id
        }
        .onChange(of: store.activePromptImprovementID) { _, id in
            if let id { selectedReportID = id; showsHistory = false }
        }
    }

    private var configureAction: (() -> Void)? {
        guard let configure, store.draftSuite.cases.count < 2 || store.draftSuite.scoringMode == .review else { return nil }
        return { dismiss(); configure(store.draftSuite.cases.count < 2) }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if report == nil && !showsHistory {
                if let budget = PromptImprovementPresentation.maximumSamples(suite: store.draftSuite, heldOutCaseIDs: heldOutCaseIDs) {
                    Text("Up to \(budget) responses · Suggestions written on this Mac")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let issue {
                    Text(issue).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if showsHistory {
                    Button("Back") { showsHistory = false }
                } else if isActive {
                    Button("Cancel comparison", role: .cancel) { store.cancelRun() }
                        .accessibilityIdentifier("Cancel run")
                } else if let report {
                    Button("New comparison") { selectedReportID = nil; errorMessage = nil }
                        .disabled(isBusy)
                    if report.canApply && report.appliedAt == nil {
                        Button("Use suggestion", systemImage: "checkmark") {
                            do { try store.applyPromptImprovement(id: report.id) }
                            catch { errorMessage = error.localizedDescription }
                        }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(isStale || isBusy).accessibilityIdentifier("Apply validated instructions")
                    }
                } else {
                    if isBusy { Text("Wait for the current task to finish.").font(.caption).foregroundStyle(.secondary) }
                    Button("Compare suggestions", systemImage: "sparkles") {
                        do {
                            errorMessage = nil
                            try store.startPromptImprovement(heldOutCaseIDs: heldOutCaseIDs)
                        } catch { errorMessage = error.localizedDescription }
                    }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(issue != nil || isBusy).accessibilityIdentifier("Generate and compare instructions")
                }
            }
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }

    private func progress(_ report: EvaluationPromptImprovement) -> some View {
        let presentation = PromptImprovementPresentation(report: report, isActive: true)
        return VStack(alignment: .leading, spacing: 20) {
            EditorSection("\(presentation.title)", description: "\(presentation.progressDetail)") {
                ProgressView(value: Double(store.completedSamples), total: Double(max(1, store.totalSamples)))
                    .accessibilityLabel("Comparison progress")
                Text("\(store.completedSamples) of up to \(store.totalSamples) responses completed")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Divider()
                ForEach(Array(["Check current instructions", "Write two suggestions", "Compare practice results", "Run the final check"].enumerated()), id: \.offset) { index, title in
                    HStack(spacing: 10) {
                        if index == presentation.step { ProgressView().controlSize(.small).frame(width: 18) }
                        else { Image(systemName: index < presentation.step ? "checkmark.circle.fill" : "circle").foregroundStyle(index < presentation.step ? WorkspaceStyle.success : Color.secondary).frame(width: 18) }
                        Text(title).font(.callout).foregroundStyle(index > presentation.step ? .secondary : .primary)
                    }
                }
            }
            WorkspaceNotice(.info, message: presentation.detail)
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comparison history").font(.headline)
            ForEach(reports.reversed()) { report in
                Button {
                    selectedReportID = report.id; showsHistory = false; errorMessage = nil
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: report.appliedAt != nil ? "checkmark.circle" : "clock").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(PromptImprovementPresentation(report: report, isActive: store.activePromptImprovementID == report.id,
                                isStale: store.draftSuite != report.source || store.suite != report.source).title).font(.callout.weight(.semibold))
                            Text(report.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }.padding(16).contentShape(Rectangle())
                }.buttonStyle(.plain).workspaceSurface()
            }
        }
    }
}
