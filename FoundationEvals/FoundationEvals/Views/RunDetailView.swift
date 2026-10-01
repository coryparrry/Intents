import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum ResultFilter: String, CaseIterable, Identifiable {
    case all
    case passed
    case failed
    case issues

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .all: "All"
        case .passed: "Passed"
        case .failed: "Failed"
        case .issues: "Issues"
        }
    }

    func includes(_ result: EvaluationSampleResult) -> Bool {
        switch self {
        case .all:
            true
        case .passed:
            result.status == .passed
        case .failed:
            result.status == .failed
        case .issues:
            result.status == .error || result.status == .unscored || result.judgeErrorMessage != nil
        }
    }
}

struct RunDetailView: View {
    let run: EvaluationRun
    let baselineRuns: [EvaluationRun]
    @State private var exportDocument = JSONDocument()
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var showsWorkflow = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Run view", selection: $showsWorkflow) {
                    Text("Workflow trace").tag(true)
                    Text("Report").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                .accessibilityIdentifier("Run view")
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            if showsWorkflow {
                WorkflowTraceView(run: run)
                    .id(run.id)
            } else {
                report
            }
        }
        .navigationTitle(run.suiteName)
        .toolbar {
            Button("Export Run as JSON", systemImage: "square.and.arrow.up") {
                do {
                    exportDocument = try JSONDocument(run: run)
                    isExporting = true
                } catch {
                    exportError = error.localizedDescription
                }
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "\(safeFilename(run.suiteName))-\(run.suiteVersion)-\(run.id.uuidString.prefix(8)).json"
        ) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert("Could not export run", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    private var report: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                RunOverviewHeader(run: run)
                RunSummaryDashboard(run: run)
                ResultsSection(run: run)
                    .id(run.id)
                RunAnalysisSection(run: run, baselineRuns: baselineRuns)
                RunConfigurationSection(run: run)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.primary.opacity(0.025))
    }

    private func safeFilename(_ value: String) -> String {
        value.replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "-", options: .regularExpression)
    }
}

private struct RunOverviewHeader: View {
    let run: EvaluationRun

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(run.suiteName)
                    .font(.system(size: 26, weight: .semibold))
                Spacer()
                RunStatusBadge(run: run)
            }

            HStack(spacing: 10) {
                Text(run.suiteVersion)
                Text("·")
                Text(run.scoringMode.title)
                Text("·")
                Text(run.startedAt, format: .dateTime.year().month().day().hour().minute().second())
                Text("·")
                Text(run.totalDuration.formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }
}

private struct RunStatusBadge: View {
    let run: EvaluationRun

    private var title: LocalizedStringResource {
        if run.cancelled { return "Cancelled" }
        if run.stoppedEarly { return "Stopped early" }
        if run.errorCount > 0 { return "Completed with issues" }
        if run.failedCount > 0 { return "Completed with failures" }
        return "Completed"
    }

    private var symbol: String {
        if run.cancelled { return "stop.circle.fill" }
        if run.stoppedEarly || run.errorCount > 0 { return "exclamationmark.circle.fill" }
        if run.failedCount > 0 { return "xmark.circle.fill" }
        return "checkmark.circle.fill"
    }

    private var color: Color {
        if run.cancelled || run.stoppedEarly { return .orange }
        return run.errorCount > 0 || run.failedCount > 0 ? .red : .green
    }

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.09), in: .capsule)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
            .accessibilityIdentifier("Run status")
    }
}

private struct RunConfigurationSection: View {
    let run: EvaluationRun

    var body: some View {
        DisclosureGroup("Run configuration") {
            VStack(alignment: .leading, spacing: 14) {
                LabeledText(label: "Instructions", text: run.instructions.isEmpty ? "None" : run.instructions)
                if let execution = run.execution {
                    let configuration = execution.configuration
                    LabeledText(
                        label: "Model provider",
                        text: "\(execution.modelDisplayName) · \(configuration.provider.title)"
                    )
                    LabeledText(
                        label: "Reasoning and generation",
                        text: "Reasoning \(configuration.reasoningLevel.title) · \(configuration.samplingSummary) · temperature \(configuration.temperatureEnabled ? configuration.temperature.formatted(.number.precision(.fractionLength(2))) : "automatic") · maximum \(configuration.maximumResponseTokens) response tokens"
                    )
                    LabeledText(
                        label: "Context and references",
                        text: contextSummary(execution: execution)
                    )
                    LabeledText(
                        label: "Execution contract",
                        text: "\(execution.behaviorVersion) · capabilities: \(execution.capabilities.joined(separator: ", ")) · tools: \(execution.toolNames.isEmpty ? "none" : execution.toolNames.joined(separator: ", "))"
                    )
                    if let features = execution.features {
                        FeatureConfigurationSummary(configuration: features)
                    }
                }
                if run.scoringMode == .modelJudge {
                    LabeledText(label: "AI rubric requirements", text: run.criteria)
                    LabeledText(
                        label: "AI judge",
                        text: "Prompt \(run.judgePromptVersion ?? "legacy") · scores \(run.judgePassingScore ?? EvaluationSuite.judgePassingScore)–4 pass · selected provider with fixed greedy decoding and tools off"
                    )
                }
                LabeledText(
                    label: "Environment",
                    text: "\(run.environment.model) · \(run.environment.modelContextSize) token context · \(run.environment.operatingSystem) · \(run.environment.locale)"
                )
                if !run.attachments.isEmpty {
                    LabeledText(
                        label: "Shared reference files",
                        text: run.attachments.map {
                            "\($0.name) (\($0.kind.rawValue), \($0.byteCount) bytes, SHA-256 \($0.sha256))"
                        }.joined(separator: "\n")
                    )
                }
            }
            .padding(.top, 12)
        }
        .font(.headline)
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.14))
        }
    }

    private func contextSummary(execution: EvaluationExecutionTrace) -> String {
        let configuration = execution.configuration
        let requested = configuration.maximumInputTokens.map { "\($0) tokens" } ?? "automatic"
        let effective = execution.effectiveInputTokenLimit.map { " · effective \($0) tokens" } ?? ""
        let toolReserve = execution.reservedToolOutputTokens.flatMap { $0 > 0 ? " · tool reserve \($0) tokens" : nil } ?? ""
        let judgeReserve = execution.reservedJudgeOverheadTokens.flatMap { $0 > 0 ? " · judge reserve \($0) tokens" : nil } ?? ""
        let counting = execution.inputTokenCountingMethod.map { " · \($0)" } ?? ""
        let imageCounting = execution.imageInputTokenCountAvailable == false
            ? " · image input token count unavailable"
            : ""
        return "Requested \(requested)\(effective)\(toolReserve)\(judgeReserve)\(counting)\(imageCounting) · \(configuration.contextPolicy.title) · \(configuration.referenceMode.title)"
    }
}

private struct ResultsSection: View {
    let run: EvaluationRun
    @State private var filter = ResultFilter.all
    @State private var searchText = ""
    @State private var selectedResultID: UUID?

    private var results: [EvaluationSampleResult] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return run.results.filter { result in
            filter.includes(result)
                && (query.isEmpty
                    || result.caseName.localizedCaseInsensitiveContains(query)
                    || result.prompt.localizedCaseInsensitiveContains(query)
                    || result.response.localizedCaseInsensitiveContains(query)
                    || result.reasoningText?.localizedCaseInsensitiveContains(query) == true
                    || result.judgeReasoningText?.localizedCaseInsensitiveContains(query) == true
                    || result.errorMessage?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    private var isFiltering: Bool {
        filter != .all || !searchText.isEmpty
    }

    private var selectedResult: EvaluationSampleResult? {
        guard let selectedResultID else { return results.first }
        return results.first(where: { $0.id == selectedResultID }) ?? results.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Results")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(isFiltering ? "\(results.count) of \(run.results.count)" : "\(run.results.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: .rect(cornerRadius: 4))
                Spacer()
                if !run.results.isEmpty {
                    Picker("Result filter", selection: $filter) {
                        ForEach(ResultFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 110)

                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.tertiary)
                        TextField("Search results", text: $searchText)
                            .textFieldStyle(.plain)
                            .accessibilityLabel("Search case, prompt, or response")
                        if isFiltering {
                            Button("Clear filters", systemImage: "xmark.circle.fill") { clearFilters() }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("Clear result filters")
                        }
                    }
                    .padding(8)
                    .frame(width: 220)
                    .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 6))
                }
            }
            .padding(18)

            if run.results.isEmpty {
                ContentUnavailableView(
                    run.cancelled ? "Cancelled Before Results" : "No Results Collected",
                    systemImage: run.cancelled ? "stop.circle" : "tray",
                    description: Text(run.cancelled
                        ? "This run was cancelled before a response was collected. Start a new run from the Suite Editor."
                        : "This run did not collect any responses. Review its configuration and start a new run from the Suite Editor.")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            } else if results.isEmpty {
                ContentUnavailableView(
                    "No Matching Results",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Change the filter or search text to see more results.")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                Table(results, selection: $selectedResultID) {
                    TableColumn("Case") { result in
                        Text(result.caseName)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .width(min: 160, ideal: 300)
                    TableColumn("Outcome") { result in
                        ResultStatusLabel(result: result)
                    }
                    .width(min: 90, ideal: 110)
                    TableColumn("Score") { result in
                        Text(result.score.map { "\($0) / 4" } ?? "—")
                            .monospacedDigit()
                            .foregroundStyle(result.score == nil ? Color.secondary : Color.accentColor)
                    }
                    .width(70)
                    TableColumn("Latency") { result in
                        Text(Duration.milliseconds(result.durationMilliseconds)
                            .formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated)))
                            .monospacedDigit()
                    }
                    .width(min: 90, ideal: 110)
                    TableColumn("Tokens") { result in
                        Text(result.usage.totalTokens.formatted())
                            .monospacedDigit()
                    }
                    .width(75)
                    TableColumn("Repetition") { result in
                        Text("\(result.repetition) / \(run.repetitions)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(80)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .frame(height: min(320, max(160, CGFloat(results.count) * 30 + 40)))
                .accessibilityIdentifier("Result list")

                if let selectedResult {
                    Divider()
                    ResultDetail(
                        result: selectedResult,
                        scoringMode: run.scoringMode,
                        repetitions: run.repetitions,
                        passingScore: run.judgePassingScore ?? EvaluationSuite.judgePassingScore,
                        modelConfiguration: run.execution?.configuration
                    )
                    .id(selectedResult.id)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
        .clipShape(.rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .onAppear { selectFirstResultIfNeeded() }
        .onChange(of: results.map(\.id)) { _, _ in
            selectFirstResultIfNeeded()
        }
    }

    private func clearFilters() {
        filter = .all
        searchText = ""
    }

    private func selectFirstResultIfNeeded() {
        if selectedResultID.flatMap({ id in results.firstIndex(where: { $0.id == id }) }) == nil {
            selectedResultID = results.first?.id
        }
    }
}

private struct ResultStatusLabel: View {
    let result: EvaluationSampleResult

    var body: some View {
        Label(statusTitle, systemImage: statusSymbol)
            .font(.caption)
            .foregroundStyle(statusColor)
            .accessibilityElement(children: .combine)
    }

    private var statusTitle: String {
        switch result.status {
        case .passed: "Passed"
        case .failed: "Failed"
        case .unscored: "Unscored"
        case .error: "Error"
        }
    }

    private var statusSymbol: String {
        switch result.status {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .unscored: "circle.dotted"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch result.status {
        case .passed: .green
        case .failed, .error: .red
        case .unscored: .secondary
        }
    }
}

private struct ResultDetail: View {
    let result: EvaluationSampleResult
    let scoringMode: ScoringMode
    let repetitions: Int
    let passingScore: Int
    let modelConfiguration: EvaluationModelConfiguration?
    @State private var hasCopiedResponse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ResultCardHeader(
                result: result,
                repetitions: repetitions,
                passingScore: passingScore
            )

            Divider()

            if let errorMessage = result.errorMessage {
                ErrorBanner(
                    title: "Response failed",
                    message: errorMessage,
                    category: result.errorCategory
                )
            }
            if let refusal = result.refusal {
                RefusalExplanationView(trace: refusal)
            }

            LabeledText(label: "Prompt", text: result.prompt)

            if let effectivePrompt = result.effectivePrompt, effectivePrompt != result.prompt {
                LabeledText(label: "Effective model input", text: effectivePrompt)
            }

            if !result.expected.isEmpty {
                LabeledText(label: "Expected or reference answer", text: result.expected)
            }

            ResponseTextBlock(
                response: result.response,
                hasCopied: hasCopiedResponse,
                copy: copyResponse
            )

            if result.reasoningText != nil || result.usage.reasoningTokens > 0 {
                ReasoningTraceSection(
                    title: "Response reasoning",
                    text: result.reasoningText,
                    tokenCount: result.usage.reasoningTokens
                )
            }

            if let rationale = result.rationale {
                LabeledText(
                    label: "Scoring rationale",
                    text: rationale
                )
            }

            if result.judgeReasoningText != nil || (result.judgeUsage?.reasoningTokens ?? 0) > 0 {
                ReasoningTraceSection(
                    title: "AI judge reasoning",
                    text: result.judgeReasoningText,
                    tokenCount: result.judgeUsage?.reasoningTokens ?? 0
                )
            }

            if let judgeErrorMessage = result.judgeErrorMessage {
                ErrorBanner(
                    title: "AI scoring failed",
                    message: judgeErrorMessage,
                    category: result.judgeErrorCategory
                )
            }
            if let refusal = result.judgeTrace?.refusal {
                RefusalExplanationView(trace: refusal, title: "Why the judge refused")
            }

            SampleTraceSection(result: result)
            if let assertions = result.fieldAssertionResults, !assertions.isEmpty {
                FieldAssertionEvidenceSection(results: assertions)
            }
            if let trace = result.featureTrace { FeatureTraceSection(trace: trace) }
            if let transcript = result.featureTrace?.transcript {
                TranscriptFeedbackSection(
                    trace: transcript,
                    configuration: modelConfiguration,
                    caseName: result.caseName,
                    repetition: result.repetition
                )
            }
            if let trace = result.judgeTrace { JudgeEvidenceSection(trace: trace) }
        }
        .textSelection(.enabled)
    }

    private func copyResponse() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(result.response, forType: .string)
        hasCopiedResponse = true
    }
}

private struct ReasoningTraceSection: View {
    let title: LocalizedStringResource
    let text: String?
    let tokenCount: Int

    var body: some View {
        DisclosureGroup(title) {
            Text(text ?? "The model used \(tokenCount) reasoning tokens, but did not expose readable reasoning for this response.")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        }
        .font(.callout)
    }
}

private struct ResultCardHeader: View {
    let result: EvaluationSampleResult
    let repetitions: Int
    let passingScore: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.caseName)
                    .font(.headline)
                if repetitions > 1 {
                    Text("Repetition \(result.repetition) of \(repetitions)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(statusTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusColor.opacity(0.09), in: .capsule)

            if let score = result.score {
                Text("\(score) / 4")
                    .font(.headline.monospacedDigit())
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusTitle: String {
        switch result.status {
        case .passed: "Passed"
        case .failed: "Failed"
        case .unscored: "Unscored"
        case .error: "Error"
        }
    }

    private var statusSymbol: String {
        switch result.status {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .unscored: "circle.dotted"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch result.status {
        case .passed: .green
        case .failed, .error: .red
        case .unscored: .secondary
        }
    }
}

private struct ResponseTextBlock: View {
    let response: String
    let hasCopied: Bool
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Response")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !response.isEmpty {
                    Button(
                        hasCopied ? "Copied" : "Copy Response",
                        systemImage: hasCopied ? "checkmark" : "doc.on.doc",
                        action: copy
                    )
                    .buttonStyle(.borderless)
                }
            }
            Text(response.isEmpty ? "No response was captured." : response)
                .foregroundStyle(response.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ErrorBanner: View {
    let title: LocalizedStringResource
    let message: String
    let category: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(message)
                if let category {
                    Text(category)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 9))
    }
}

private struct LabeledText: View {
    let label: LocalizedStringResource
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
