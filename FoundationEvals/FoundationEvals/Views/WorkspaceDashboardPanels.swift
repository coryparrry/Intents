import SwiftUI

struct WorkspaceSuiteRow: View {
    let summary: SuiteOverviewSummary?
    let name: String
    let isRunning: Bool
    let disabled: Bool
    let open: () -> Void
    let run: () -> Void

    private var detail: String {
        guard let summary else { return "Loading saved results…" }
        var parts = ["\(summary.caseCount) \(summary.caseCount == 1 ? "case" : "cases")", "\(summary.repetitions)× repetitions"]
        if let checked = summary.lastCheckedAt {
            parts.append("checked " + checked.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: 12) {
                    WorkspaceIconTile(symbol: "checklist", tint: .accentColor, size: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary?.name ?? name).font(.body.weight(.semibold))
                            .foregroundStyle(.primary).lineLimit(1)
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let error = summary?.loadError {
                            Text(error).font(.caption).foregroundStyle(WorkspaceStyle.warning).lineLimit(2)
                        } else if summary?.repositoryChanged == true {
                            Text("Repository definition changed").font(.caption).foregroundStyle(WorkspaceStyle.warning)
                        }
                    }
                    Spacer(minLength: 12)
                    if summary?.approvedRunID != nil {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(WorkspaceStyle.success)
                            .help("Baseline approved").accessibilityLabel("Baseline approved")
                    }
                    if let summary { WorkspaceStatusBadge(state: summary.state) }
                }
                .padding(.vertical, 12).padding(.leading, 18).padding(.trailing, 10)
            }
            .buttonStyle(WorkspaceRowButtonStyle())
            .disabled(disabled)
            Group {
                if isRunning {
                    ProgressView().controlSize(.small).accessibilityLabel("Running suite")
                } else {
                    Button(action: run) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 20))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Run \(summary?.name ?? name)")
                    .help(summary?.loadError ?? "Run checks")
                    .disabled(disabled || summary == nil || summary?.state == .unavailable)
                }
            }
            .frame(width: 30)
            .padding(.trailing, 14)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Suite overview \(name)")
    }
}

/// The project's health at a glance: a ring of suite states beside the headline numbers.
struct WorkspaceHealthPanel: View {
    let summaries: [SuiteOverviewSummary]
    let total: Int
    let isLoaded: Bool
    let compact: Bool

    private var passed: Int { summaries.filter { $0.state == .passed }.count }
    private var attention: Int { summaries.filter { $0.state.needsAttention }.count }
    private var awaiting: Int { summaries.filter { $0.state == .notRun || $0.state == .collected }.count }
    private var loading: Int { max(0, total - summaries.count) }
    private var cases: Int { summaries.reduce(0) { $0 + $1.caseCount } }
    private var latest: Date? { summaries.compactMap(\.lastCheckedAt).max() }

    var body: some View {
        let layout = compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 28))
        layout {
            HStack(spacing: 24) {
                ring
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Suite health").font(.headline)
                        Text("Each suite’s latest check against its current definition.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    legend("Passing", count: passed, color: WorkspaceStyle.success)
                    legend("Needs attention", count: attention, color: WorkspaceStyle.warning)
                    legend("Not run or awaiting assessment", count: awaiting, color: Color.secondary.opacity(0.45))
                    if loading > 0 { legend("Loading", count: loading, color: Color.secondary.opacity(0.25)) }
                }
                .frame(maxWidth: 300, alignment: .leading)
            }
            if !compact { Divider().frame(height: 110) }
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 18) {
                GridRow {
                    WorkspaceMetric(title: "Suites", value: total.formatted(), detail: "In this project",
                                    symbol: "square.stack", color: .accentColor)
                    WorkspaceMetric(title: "Test cases",
                                    value: !isLoaded || summaries.contains { $0.loadError != nil } ? "—" : cases.formatted(),
                                    detail: summaries.contains { $0.loadError != nil } ? "Some suites unavailable" : "Across your suites",
                                    symbol: "checklist", color: .indigo)
                }
                GridRow {
                    WorkspaceMetric(title: "Needs attention", value: isLoaded ? attention.formatted() : "—",
                                    detail: "Changed or incomplete", symbol: "flag.fill", color: WorkspaceStyle.warning)
                    WorkspaceMetric(title: "Last check",
                                    value: latest.map { $0.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)) } ?? "—",
                                    detail: latest == nil ? "No runs yet" : "Most recent saved run",
                                    symbol: "clock", color: .teal)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workspaceSurface()
        .accessibilityElement(children: .contain)
    }

    private var ring: some View {
        ZStack {
            WorkspaceRing(
                segments: [
                    WorkspaceRingSegment(count: passed, color: WorkspaceStyle.success),
                    WorkspaceRingSegment(count: attention, color: WorkspaceStyle.warning),
                    WorkspaceRingSegment(count: awaiting, color: Color.secondary.opacity(0.35))
                ],
                total: max(total, 1),
                lineWidth: 12
            )
            VStack(spacing: 0) {
                Text(isLoaded ? passed.formatted() : "—")
                    .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("of \(total) passing").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 118, height: 118)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Suite health")
        .accessibilityValue(isLoaded ? "\(passed) of \(total) suites passing" : "Loading")
    }

    private func legend(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 8) {
            WorkspaceStatusDot(color: color, size: 8)
            Text(title).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 12)
            Text(count.formatted()).monospacedDigit().fontWeight(.semibold)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

struct WorkspaceActivityCard: View {
    let summaries: [SuiteOverviewSummary]
    let disabled: Bool
    let open: (SuiteOverviewSummary) -> Void
    private var recent: [SuiteOverviewSummary] {
        Array(summaries.filter { $0.lastCheckedAt != nil }
            .sorted { ($0.lastCheckedAt ?? .distantPast) > ($1.lastCheckedAt ?? .distantPast) }.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspacePanelHeader("Latest checks")
            if recent.isEmpty {
                WorkspaceEmptyState(symbol: "clock.arrow.circlepath", title: "A fresh start",
                                    detail: "Run a suite to see its latest check here. Every response and trace stays available for review.")
                    .padding(.top, -12)
            } else {
                ForEach(recent) { summary in
                    Button { open(summary) } label: { row(summary) }
                        .buttonStyle(WorkspaceRowButtonStyle()).disabled(disabled)
                    if summary.id != recent.last?.id { Divider().padding(.leading, 18) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, recent.isEmpty ? 0 : 6)
        .workspaceSurface()
    }

    private func row(_ summary: SuiteOverviewSummary) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                WorkspaceStatusDot(color: summary.state.color, size: 8)
                Text(summary.name).font(.callout.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 4)
                if let date = summary.lastCheckedAt {
                    Text(date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
                        .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
            WorkspaceProportionBar(segments: [
                WorkspaceRingSegment(count: summary.passedCount, color: WorkspaceStyle.success),
                WorkspaceRingSegment(count: summary.failedCount, color: WorkspaceStyle.failure),
                WorkspaceRingSegment(count: summary.errorCount, color: WorkspaceStyle.warning)
            ], height: 5)
            Text("\(summary.passedCount) passed · \(summary.failedCount) failed · \(summary.errorCount) errors")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}
