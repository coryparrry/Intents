//
//  ContentView.swift
//  FoundationEvals
//
//  Created by Cory Parry on 01/09/2026.
//

import SwiftUI

struct ContentView: View {
    @Bindable var store: EvaluationStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly

    var body: some View {
        VStack(spacing: 0) {
            workspaceNavigation
            WorkbenchStatusBar(store: store)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("Workspace status")
        }
        .frame(minWidth: 1_000, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                WorkspaceResetControl(store: store)
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("MCP Connector", systemImage: "network")
                }
                .help("MCP Connector settings")
            }
        }
        .background { SuiteAutosaveObserver(store: store) }
        .alert(
            "Foundation Evals",
            isPresented: Binding(
                get: { store.notice != nil },
                set: { if !$0 { store.notice = nil } }
            )
        ) {
            Button("OK") { store.notice = nil }
        } message: {
            Text(store.notice ?? "")
        }
    }

    private var workspaceNavigation: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            RunHistorySidebar(store: store)
        } detail: {
            switch store.selection {
            case .suite:
                SuiteEditorView(store: store)
                    .disclosureGroupStyle(FullWidthDisclosureStyle())
            case .run(let id):
                if let run = store.run(with: id) {
                    RunDetailView(
                        run: run,
                        baselineRuns: store.runs.filter {
                            $0.id != run.id
                                && $0.suiteID == run.suiteID
                                && $0.startedAt < run.startedAt
                        }
                    )
                    .disclosureGroupStyle(FullWidthDisclosureStyle())
                } else {
                    ContentUnavailableView(
                        "Run Not Found",
                        systemImage: "exclamationmark.triangle",
                        description: Text("The saved run may have been removed.")
                    )
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private struct RunHistorySidebar: View {
    @Bindable var store: EvaluationStore
    @State private var searchText = ""
    @State private var runToDelete: EvaluationRun?
    @State private var isConfirmingDeletion = false

    private var visibleRuns: [EvaluationRun] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.runs }
        return store.runs.filter {
            $0.suiteName.localizedCaseInsensitiveContains(query)
                || $0.suiteVersion.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        SidebarNavigationList(selection: $store.selection) {
            Section {
                SuiteSidebarRow(
                    caseCount: store.draftSuite.cases.count,
                    repetitions: store.draftSuite.repetitions
                )
                .tag(SidebarSelection.suite)
            }

            Section("Run History") {
                if visibleRuns.isEmpty {
                    EmptyRunHistoryRow(isSearching: !searchText.isEmpty)
                } else {
                    ForEach(visibleRuns) { run in
                        RunSidebarRow(run: run)
                            .tag(SidebarSelection.run(run.id))
                            .contextMenu {
                                Button("Delete Run", systemImage: "trash", role: .destructive) {
                                    runToDelete = run
                                    isConfirmingDeletion = true
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Foundation Evals")
        .frame(minWidth: 250)
        .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 340)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search runs")
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("FOUNDATION")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(2)
                    Text("Evaluation lab")
                        .font(.system(size: 17, weight: .semibold))
                }
                Spacer()
            }
            .padding(18)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .combine)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SettingsLink {
                Label("MCP Connector", systemImage: "network")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("Open MCP Connector")
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .top) {
                Divider()
            }
        }
        .confirmationDialog(
            "Delete this run?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible,
            presenting: runToDelete
        ) { run in
            Button("Delete Run", role: .destructive) {
                store.deleteRun(id: run.id)
                runToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                runToDelete = nil
            }
        } message: { run in
            Text("This permanently removes the local trace for \(run.suiteName) from \(run.startedAt.formatted(date: .abbreviated, time: .shortened)).")
        }
    }
}

private struct SuiteSidebarRow: View {
    let caseCount: Int
    let repetitions: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist")
                .foregroundStyle(.tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text("Suite Editor")
                    .fontWeight(.medium)
                Text("\(caseCount) case\(caseCount == 1 ? "" : "s") · \(repetitions)× each")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RunSidebarRow: View {
    let run: EvaluationRun

    private var statusSummary: String {
        if run.cancelled { return "Cancelled · \(run.results.count) of \(run.plannedResultCount)" }
        if run.stoppedEarly { return "\(run.terminationSummary ?? "Stopped early") · \(run.results.count) of \(run.plannedResultCount)" }
        if run.errorCount > 0 { return "\(run.errorCount) issue\(run.errorCount == 1 ? "" : "s")" }
        if let passRate = run.passRate {
            return "\(passRate.formatted(.percent.precision(.fractionLength(0)))) passed"
        }
        return "\(run.results.count) collected"
    }

    private var statusSymbol: String {
        if run.cancelled || run.stoppedEarly { return "exclamationmark.circle.fill" }
        if run.errorCount > 0 || run.failedCount > 0 { return "xmark.circle.fill" }
        if run.scoredCount > 0 { return "checkmark.circle.fill" }
        return "circle.dotted"
    }

    private var statusColor: Color {
        if run.cancelled || run.stoppedEarly { return .orange }
        if run.errorCount > 0 || run.failedCount > 0 { return .red }
        if run.scoredCount > 0 { return .green }
        return .secondary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(run.suiteName)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(run.suiteVersion)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 4) {
                    Text(statusSummary)
                    Text("·")
                    Text(run.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(run.suiteName)
        .accessibilityValue("\(statusSummary), \(run.startedAt.formatted(date: .abbreviated, time: .standard))")
    }
}

private struct EmptyRunHistoryRow: View {
    let isSearching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                isSearching ? "No matching runs" : "No runs yet",
                systemImage: isSearching ? "magnifyingglass" : "clock.arrow.circlepath"
            )
                .font(.callout.weight(.medium))
            Text(isSearching ? "Try a different suite name or version." : "Completed runs and their local traces appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ContentView(store: EvaluationStore())
}
