import SwiftUI

struct WorkspaceSuiteRow: View {
    let summary: SuiteOverviewSummary?
    let name: String
    let isRunning: Bool
    let disabled: Bool
    let open: () -> Void
    let run: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: open) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checklist")
                        .font(.system(size: 17, weight: .medium)).foregroundStyle(Color.accentColor)
                        .frame(width: 36, height: 36)
                        .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(summary?.name ?? name).font(.callout.weight(.semibold))
                            .foregroundStyle(.primary).lineLimit(2)
                        if let summary {
                            Text("\(summary.caseCount) \(summary.caseCount == 1 ? "case" : "cases") · \(summary.repetitions)× repetitions")
                                .font(.caption).foregroundStyle(.secondary)
                            WorkspaceStatusBadge(state: summary.state)
                            if let error = summary.loadError {
                                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            } else if summary.repositoryChanged {
                                Text("Repository definition changed").font(.caption).foregroundStyle(WorkspaceStyle.warning)
                            }
                        } else {
                            Text("Loading saved results…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 18).padding(.leading, 20)
            }
            .buttonStyle(WorkspaceRowButtonStyle())
            .disabled(disabled)
            VStack(alignment: .trailing, spacing: 14) {
                if isRunning {
                    ProgressView().controlSize(.small).accessibilityLabel("Running suite")
                } else {
                    Button(action: run) { Image(systemName: "play.fill").font(.system(size: 10)) }
                        .buttonStyle(.bordered).buttonBorderShape(.circle)
                        .accessibilityLabel("Run \(summary?.name ?? name)")
                        .help(summary?.loadError ?? "Run checks")
                        .disabled(disabled || summary == nil || summary?.state == .unavailable)
                }
                if summary?.approvedRunID != nil {
                    Image(systemName: "checkmark.seal").foregroundStyle(WorkspaceStyle.success)
                        .help("Baseline approved").accessibilityLabel("Baseline approved")
                }
            }
            .padding(.top, 20).padding(.trailing, 18)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Suite overview \(name)")
    }
}

struct WorkspaceCoverageCard: View {
    let summaries: [SuiteOverviewSummary]
    let total: Int
    private var passed: Int { summaries.filter { $0.state == .passed }.count }
    private var attention: Int { summaries.filter { $0.state.needsAttention }.count }
    private var awaiting: Int { summaries.filter { $0.state == .notRun || $0.state == .collected }.count }
    private var loading: Int { max(0, total - summaries.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Suite health").font(.headline)
                Spacer()
                Image(systemName: "waveform.path.ecg").foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(loading > 0 ? "—" : passed.formatted())
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                Text("/ \(total)").font(.title3).foregroundStyle(.tertiary)
                Spacer()
                Text(loading > 0 ? "loading" : "passing").font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                HStack(spacing: 3) {
                    segment(passed, color: WorkspaceStyle.success, width: geometry.size.width)
                    segment(attention, color: WorkspaceStyle.warning, width: geometry.size.width)
                    segment(awaiting + loading, color: .secondary.opacity(0.22), width: geometry.size.width)
                }
            }
            .frame(height: 7).accessibilityHidden(true)
            VStack(spacing: 12) {
                legend("Passing", count: passed, color: WorkspaceStyle.success)
                legend("Needs attention", count: attention, color: WorkspaceStyle.warning)
                legend("Not run / awaiting assessment", count: awaiting, color: .secondary)
                if loading > 0 { legend("Loading", count: loading, color: .secondary) }
            }
            Divider()
            Text("Based on each suite’s latest check against its current definition.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).workspaceSurface()
    }

    @ViewBuilder private func segment(_ count: Int, color: Color, width: CGFloat) -> some View {
        if count > 0 {
            Capsule().fill(color).frame(width: max(0, width - 6) * CGFloat(count) / CGFloat(max(total, 1)))
        }
    }

    private func legend(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Text(count.formatted()).monospacedDigit().fontWeight(.medium)
        }
        .font(.caption).accessibilityElement(children: .combine)
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
            HStack {
                Text("Latest checks").font(.headline)
                Spacer()
                Image(systemName: "clock").foregroundStyle(.secondary)
            }
            .padding(20)
            if recent.isEmpty {
                WorkspaceEmptyState(symbol: "clock.arrow.circlepath", title: "A fresh start",
                                    detail: "Run a suite to see its latest check here. Every response and trace stays available for review.")
                    .padding(.top, -8)
            } else {
                ForEach(recent) { summary in
                    Button { open(summary) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .foregroundStyle(.secondary).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(summary.name).font(.caption.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                                if let date = summary.lastCheckedAt {
                                    Text(date, style: .relative).font(.caption2).foregroundStyle(.secondary)
                                }
                                Text("\(summary.passedCount) passed · \(summary.failedCount) failed · \(summary.errorCount) errors")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 20).padding(.vertical, 12)
                    }
                    .buttonStyle(WorkspaceRowButtonStyle()).disabled(disabled)
                    if summary.id != recent.last?.id { Divider().padding(.leading, 44) }
                }
                Text("Latest saved run per suite")
                    .font(.caption2).foregroundStyle(.tertiary).padding(20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).workspaceSurface()
    }
}
