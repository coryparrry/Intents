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

    init(run: EvaluationRun, baselineRuns: [EvaluationRun]) {
        self.run = run
        self.baselineRuns = baselineRuns
        _selectedBaselineID = State(initialValue: RunBaselineSelection.defaultID(for: run, candidates: baselineRuns))
    }

    private var selectedBaseline: EvaluationRun? {
        guard let selectedBaselineID else { return nil }
        return baselineRuns.first { $0.id == selectedBaselineID }
    }

    var body: some View {
        let analysis = EvaluationRunAnalysis(run: run)

        VStack(alignment: .leading, spacing: 16) {
            RunAnalysisHeader(
                baselineRuns: baselineRuns,
                selectedBaselineID: $selectedBaselineID
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
        .background(.thinMaterial, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.secondary.opacity(0.14))
        }
        .onChange(of: run.id) { _, _ in
            selectedBaselineID = RunBaselineSelection.defaultID(for: run, candidates: baselineRuns)
        }
        .onChange(of: baselineRuns.map(\.id)) { _, ids in
            if let selectedBaselineID, !ids.contains(selectedBaselineID) {
                self.selectedBaselineID = RunBaselineSelection.defaultID(for: run, candidates: baselineRuns)
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
                Text("Percentiles exclude subject-request errors. Pass rates include scored samples only.")
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
        let date = run.startedAt.formatted(date: .abbreviated, time: .standard)
        return "\(run.suiteName) \(run.suiteVersion) · \(date) · \(run.environment.model)"
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
                detail: "\(analysis.unscoredSampleCount) unscored · \(analysis.errorSampleCount) errors · \(analysis.missingSampleCount) missing"
            )
            AnalysisMetric(
                title: "Subject latency",
                value: latency(analysis.subjectLatency.p50Milliseconds),
                detail: "p50 · p95 \(latency(analysis.subjectLatency.p95Milliseconds)) · n=\(analysis.subjectLatency.sampleCount)"
            )
            AnalysisMetric(
                title: "Subject tokens",
                value: tokenTotal(analysis.subjectUsage),
                detail: tokenDetail(analysis.subjectUsage)
            )
            AnalysisMetric(
                title: "Judge tokens",
                value: tokenTotal(analysis.judgeUsage),
                detail: analysis.judgeUsage.requestCount == 0
                    && analysis.judgeUsage.usageUnavailableSampleCount == 0
                    ? "No judge requests recorded"
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
        return "\(usage.inputTokens.formatted()) in · \(usage.outputTokens.formatted()) out · \(usage.reasoningTokens.formatted()) reasoning\(unavailable)"
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
        var parts = ["\(item.passedSampleCount)/\(item.scoredSampleCount) scored passed"]
        if item.repetitionVariation == .mixedPassAndFail { parts.append("mixed repetitions") }
        if item.errorSampleCount > 0 { parts.append("\(item.errorSampleCount) errors") }
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
                        title: "Only unchanged cases can be compared",
                        messages: [coverageMessage],
                        symbol: "circle.lefthalf.filled",
                        color: .orange
                    )
                }
                if !comparison.warnings.isEmpty {
                    ComparisonMessages(
                        title: "Run conditions changed",
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
        return "\(coverage.unchangedCaseCount) unchanged · \(coverage.changedCaseCount) changed · \(coverage.currentOnlyCaseCount) current only · \(coverage.baselineOnlyCaseCount) baseline only"
    }
}

private struct CompatibilityBadge: View {
    let compatibility: EvaluationRunComparisonCompatibility

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.1), in: .capsule)
    }

    private var title: LocalizedStringResource {
        switch compatibility {
        case .compatible: "Comparable"
        case .partialCoverage: "Partial coverage"
        case .incompatible: "Incompatible"
        }
    }

    private var color: Color {
        switch compatibility {
        case .compatible: .green
        case .partialCoverage, .incompatible: .orange
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
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.07), in: .rect(cornerRadius: 8))
    }
}

private struct ComparisonSummary: View {
    let comparison: EvaluationRunComparison

    var body: some View {
        HStack(spacing: 18) {
            Label("\(comparison.regressedCaseCount) regressed", systemImage: "arrow.down.right")
                .foregroundStyle(comparison.regressedCaseCount > 0 ? Color.red : .secondary)
            Label("\(comparison.improvedCaseCount) improved", systemImage: "arrow.up.right")
                .foregroundStyle(comparison.improvedCaseCount > 0 ? Color.green : .secondary)
            Text("\(comparison.coverage.comparableRateCaseCount) fully scored cases compared")
                .foregroundStyle(.secondary)
            if let delta = comparison.meanComparableCasePassRateDelta {
                Text("Mean case delta \(signedPercent(delta))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.callout.weight(.medium))
    }

    private func signedPercent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always()))
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
        case .subjectModelChanged: "Subject model changed."
        case .modelConfigurationChanged: "Model generation configuration changed."
        case .executionContractUnavailable: "One or both runs do not record the generation execution contract."
        case .executionContractChanged: "Execution behavior, capabilities, or tools changed."
        case .environmentChanged: "Operating system, locale, or context size changed."
        case .referencesChanged: "Shared reference files changed."
        }
    }
}
