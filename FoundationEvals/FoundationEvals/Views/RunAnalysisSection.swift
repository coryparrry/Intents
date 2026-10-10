import SwiftUI

enum RunBaselineSelection {
    static func defaultID(for run: EvaluationRun, candidates: [EvaluationRun]) -> UUID? {
        candidates
            .filter { $0.id != run.id && $0.suiteID == run.suiteID && $0.startedAt < run.startedAt }
            .sorted { $0.startedAt > $1.startedAt }
            .first { EvaluationRunComparison(current: run, baseline: $0).compatibility == .compatible }?
            .id
    }
}

struct RunAnalysisSection: View {
    let run: EvaluationRun
    let baselineRuns: [EvaluationRun]
    @State private var selectedBaselineID: UUID?
    private let externalSelection: Binding<UUID?>?

    init(run: EvaluationRun, baselineRuns: [EvaluationRun], selection: Binding<UUID?>? = nil) {
        self.run = run
        self.baselineRuns = baselineRuns
        externalSelection = selection
        _selectedBaselineID = State(initialValue: RunBaselineSelection.defaultID(for: run, candidates: baselineRuns))
    }

    private var selection: Binding<UUID?> {
        externalSelection ?? $selectedBaselineID
    }

    private var selectedBaseline: EvaluationRun? {
        guard let selectedBaselineID = selection.wrappedValue else { return nil }
        return baselineRuns.first { $0.id == selectedBaselineID }
    }

    var body: some View {
        let analysis = EvaluationRunAnalysis(run: run)

        VStack(alignment: .leading, spacing: 16) {
            RunAnalysisHeader(
                baselineRuns: baselineRuns,
                selectedBaselineID: selection
            )
            RunAnalysisMetrics(analysis: analysis)
            RunCasePatterns(cases: analysis.cases)

            if let selectedBaseline {
                Divider()
                BaselineComparisonContent(
                    comparison: EvaluationRunComparison(current: run, baseline: selectedBaseline),
                    baseline: selectedBaseline
                )
            } else if baselineRuns.isEmpty {
                Text("Run this suite again to compare scored pass rates case by case.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .workspaceSurface()
        .onChange(of: run.id) { _, _ in
            selection.wrappedValue = RunBaselineSelection.defaultID(for: run, candidates: baselineRuns)
        }
        .onChange(of: baselineRuns.map(\.id)) { _, ids in
            if let selectedBaselineID = selection.wrappedValue, !ids.contains(selectedBaselineID) {
                selection.wrappedValue = RunBaselineSelection.defaultID(for: run, candidates: baselineRuns)
            }
        }
    }
}

private struct RunAnalysisHeader: View {
    let baselineRuns: [EvaluationRun]
    @Binding var selectedBaselineID: UUID?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Analysis")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Latency percentiles exclude response errors. Pass rates use scored samples only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !baselineRuns.isEmpty {
                Picker("Baseline", selection: $selectedBaselineID) {
                    Text("No baseline").tag(Optional<UUID>.none)
                    ForEach(baselineRuns) { baseline in
                        Text(baselineLabel(baseline)).tag(Optional(baseline.id))
                    }
                }
                .accessibilityIdentifier("Baseline picker")
                .accessibilitySelectionActions(
                    [Optional<UUID>.none] + baselineRuns.map { Optional($0.id) },
                    selection: $selectedBaselineID,
                    title: { baselineID in
                        guard let baselineID,
                              let baseline = baselineRuns.first(where: { $0.id == baselineID }) else {
                            return "No baseline"
                        }
                        return baselineLabel(baseline)
                    }
                )
                .frame(maxWidth: 310)
            }
        }
    }

    private func baselineLabel(_ run: EvaluationRun) -> String {
        run.comparisonDisplayName
    }
}

private struct RunAnalysisMetrics: View {
    let analysis: EvaluationRunAnalysis

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            AnalysisMetric(
                title: "Scored",
                value: "\(analysis.scoredSampleCount) / \(analysis.completedSampleCount)",
                detail: "\(analysis.passedSampleCount) passed · \(analysis.failedSampleCount) failed"
            )
            AnalysisMetric(
                title: "Not scored",
                value: (analysis.unscoredSampleCount + analysis.errorSampleCount + analysis.missingSampleCount).formatted(),
                detail: "\(analysis.unscoredSampleCount) unscored · \(analysis.errorSampleCount) \(analysis.errorSampleCount == 1 ? "error" : "errors") · \(analysis.missingSampleCount) missing"
            )
            AnalysisMetric(
                title: "Response model latency",
                value: latency(analysis.subjectLatency.p50Milliseconds),
                detail: "Median (p50) · Estimated p95 \(latency(analysis.subjectLatency.p95Milliseconds)) · \(analysis.subjectLatency.sampleCount) samples"
            )
            .help("p50 is the middle response time. p95 estimates the time that 95% of responses fall within. Small runs give rough estimates.")
            AnalysisMetric(
                title: "Response model tokens",
                value: tokenTotal(analysis.subjectUsage),
                detail: tokenDetail(analysis.subjectUsage)
            )
            AnalysisMetric(
                title: "Scoring model tokens",
                value: tokenTotal(analysis.judgeUsage),
                detail: analysis.judgeUsage.requestCount == 0
                    && analysis.judgeUsage.usageUnavailableSampleCount == 0
                    ? "No scoring requests recorded"
                    : tokenDetail(analysis.judgeUsage)
            )
        }
    }

    private func latency(_ milliseconds: Double?) -> String {
        guard let milliseconds else { return "—" }
        return Duration.milliseconds(milliseconds)
            .formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated))
    }

    private func tokenTotal(_ usage: EvaluationTokenSummary) -> String {
        if usage.requestCount == 0 && usage.usageUnavailableSampleCount > 0 { return "—" }
        return usage.totalTokens.formatted()
    }

    private func tokenDetail(_ usage: EvaluationTokenSummary) -> String {
        if usage.requestCount == 0 && usage.usageUnavailableSampleCount > 0 {
            return "Usage unavailable for \(usage.usageUnavailableSampleCount) failed requests"
        }
        let unavailable = usage.usageUnavailableSampleCount > 0
            ? " · \(usage.usageUnavailableSampleCount) unavailable"
            : ""
        return "Text pieces · \(usage.inputTokens.formatted()) in · \(usage.outputTokens.formatted()) out · \(usage.reasoningTokens.formatted()) reasoning\(unavailable)"
    }
}

private struct AnalysisMetric: View {
    let title: LocalizedStringResource
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .padding(11)
        .background(.background.opacity(0.55), in: .rect(cornerRadius: 9))
    }
}

private struct RunCasePatterns: View {
    let cases: [EvaluationCaseAnalysis]

    private var notableCases: [EvaluationCaseAnalysis] {
        cases.filter {
            $0.failedSampleCount > 0
                || $0.unscoredSampleCount > 0
                || $0.errorSampleCount > 0
                || $0.missingSampleCount > 0
                || $0.repetitionVariation == .mixedPassAndFail
        }
    }

    var body: some View {
        DisclosureGroup("Failure and repetition patterns") {
            if notableCases.isEmpty {
                Text("No scored failures, mixed pass/fail repetitions, missing samples, or recorded issues.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(notableCases) { item in
                        CasePatternRow(item: item)
                    }
                }
                .padding(.top, 8)
            }
        }
        .font(.headline)
    }
}

private struct CasePatternRow: View {
    let item: EvaluationCaseAnalysis

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(item.caseName)
                .lineLimit(1)
            Spacer()
            Text(summary)
                .font(.callout.monospacedDigit())
                .foregroundStyle(item.repetitionVariation == .mixedPassAndFail ? Color.orange : .secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 3)
    }

    private var summary: String {
        var parts = ["\(item.passedSampleCount)/\(item.scoredSampleCount) scored responses passed"]
        if item.repetitionVariation == .mixedPassAndFail { parts.append("mixed repetitions") }
        if item.errorSampleCount > 0 { parts.append("\(item.errorSampleCount) \(item.errorSampleCount == 1 ? "error" : "errors")") }
        if item.unscoredSampleCount > 0 { parts.append("\(item.unscoredSampleCount) unscored") }
        if item.missingSampleCount > 0 { parts.append("\(item.missingSampleCount) missing") }
        return parts.joined(separator: " · ")
    }
}

private struct BaselineComparisonContent: View {
    let comparison: EvaluationRunComparison
    let baseline: EvaluationRun

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Baseline comparison")
                    .font(.headline)
                Text(baseline.startedAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                CompatibilityBadge(compatibility: comparison.compatibility)
            }

            if comparison.compatibility == .incompatible {
                ComparisonMessages(
                    title: "These runs cannot be compared",
                    messages: comparison.incompatibilityReasons,
                    symbol: "exclamationmark.triangle.fill",
                    color: .orange
                )
            } else {
                if comparison.compatibility == .partialCoverage {
                    ComparisonMessages(
                        title: "Only unchanged, fully scored cases can be compared",
                        messages: [coverageMessage],
                        symbol: "circle.lefthalf.filled",
                        color: .orange
                    )
                }
                if !comparison.warnings.isEmpty {
                    ComparisonMessages(
                        title: "Run details to review",
                        messages: comparison.warnings.map(\.title),
                        symbol: "info.circle.fill",
                        color: .blue
                    )
                }
                ComparisonSummary(comparison: comparison)
                CaseComparisonGrid(comparisons: comparison.caseComparisons)
            }
        }
    }

    private var coverageMessage: String {
        let coverage = comparison.coverage
        return "\(coverage.comparableRateCaseCount) of \(coverage.unchangedCaseCount) unchanged cases compared · \(coverage.changedCaseCount) changed · \(coverage.currentOnlyCaseCount) current only · \(coverage.baselineOnlyCaseCount) baseline only"
    }
}

private struct CompatibilityBadge: View {
    let compatibility: EvaluationRunComparisonCompatibility

    var body: some View {
        WorkspacePill(
            title,
            symbol: compatibility == .compatible ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            color: compatibility == .compatible ? WorkspaceStyle.success : WorkspaceStyle.warning
        )
    }

    private var title: String {
        switch compatibility {
        case .compatible: "Comparable"
        case .partialCoverage: "Partial coverage"
        case .incompatible: "Incompatible"
        }
    }
}

private struct ComparisonMessages: View {
    let title: LocalizedStringResource
    let messages: [String]
    let symbol: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                ForEach(messages, id: \.self) { message in
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: .rect(cornerRadius: WorkspaceStyle.controlRadius, style: .continuous))
    }
}

private struct ComparisonSummary: View {
    let comparison: EvaluationRunComparison

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                caseOutcomes
                coverage
                meanChange
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) {
                caseOutcomes
                coverage
                meanChange
            }
        }
        .font(.callout.weight(.medium))
    }

    private var caseOutcomes: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                regressedCount
                improvedCount
            }
            VStack(alignment: .leading, spacing: 8) {
                regressedCount
                improvedCount
            }
        }
    }

    private var regressedCount: some View {
        Label("\(comparison.regressedCaseCount) regressed", systemImage: "arrow.down.right")
            .foregroundStyle(comparison.regressedCaseCount > 0 ? Color.red : .secondary)
    }

    private var improvedCount: some View {
        Label("\(comparison.improvedCaseCount) improved", systemImage: "arrow.up.right")
            .foregroundStyle(comparison.improvedCaseCount > 0 ? Color.green : .secondary)
    }

    private var coverage: some View {
        Text("\(comparison.coverage.comparableRateCaseCount) fully scored cases compared")
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var meanChange: some View {
        if let delta = comparison.meanComparableCasePassRateDelta {
            Text("Mean pass-rate change \(signedPercentagePoints(delta))")
                .foregroundStyle(.secondary)
        }
    }

    private func signedPercentagePoints(_ value: Double) -> String {
        let points = (value * 100).formatted(.number.precision(.fractionLength(0)).sign(strategy: .always()))
        return "\(points) percentage points"
    }
}

private struct CaseComparisonGrid: View {
    let comparisons: [EvaluationCaseComparison]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
            GridRow {
                Text("Case")
                Text("Current")
                Text("Baseline")
                Text("Change")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            Divider()

            ForEach(comparisons) { item in
                CaseComparisonRow(comparison: item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CaseComparisonRow: View {
    let comparison: EvaluationCaseComparison

    var body: some View {
        GridRow {
            Text(comparison.caseName)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(rate(comparison.current))
                .monospacedDigit()
            Text(rate(comparison.baseline))
                .monospacedDigit()
            Label(changeTitle, systemImage: changeSymbol)
                .foregroundStyle(changeColor)
                .help(issueHelp)
        }
        .font(.callout)
    }

    private func rate(_ rate: EvaluationScoredRate?) -> String {
        guard let rate else { return "—" }
        let percent = rate.passRate?.formatted(.percent.precision(.fractionLength(0))) ?? "—"
        let planned = rate.scoredSampleCount == rate.plannedSampleCount
            ? ""
            : " of \(rate.plannedSampleCount) planned"
        return "\(percent) · \(rate.passedSampleCount)/\(rate.scoredSampleCount) scored\(planned)"
    }

    private var changeTitle: LocalizedStringResource {
        switch comparison.change {
        case .improved: "Improved"
        case .regressed: "Regressed"
        case .unchanged: "Unchanged"
        case .notComparable: "Not comparable"
        }
    }

    private var changeSymbol: String {
        switch comparison.change {
        case .improved: "arrow.up.right"
        case .regressed: "arrow.down.right"
        case .unchanged: "minus"
        case .notComparable: "questionmark.circle"
        }
    }

    private var changeColor: Color {
        switch comparison.change {
        case .improved: .green
        case .regressed: .red
        case .unchanged: .secondary
        case .notComparable: .orange
        }
    }

    private var issueHelp: String {
        switch comparison.issue {
        case .missingFromCurrentRun: "The case is absent from the current run."
        case .missingFromBaselineRun: "The case is absent from the baseline run."
        case .caseDefinitionChanged: "The prompt or expected response changed."
        case .incompleteScoredCoverage: "One or both runs lack a scored result for every planned repetition."
        case nil: "Current and baseline pass rates use all planned scored repetitions."
        }
    }
}

private extension EvaluationRunComparisonWarning {
    var title: String {
        switch self {
        case .suiteVersionChanged: "Suite version changed."
        case .instructionsChanged: "Suite instructions changed."
        case .subjectModelChanged: "Response model changed."
        case .modelConfigurationChanged: "Response model settings changed."
        case .executionContractUnavailable: "Some saved run settings are missing from one or both runs."
        case .executionContractChanged: "Model behavior, supported features, or tools changed."
        case .environmentChanged: "Operating system, language, or context size changed."
        case .referencesChanged: "Shared reference files changed."
        }
    }
}
