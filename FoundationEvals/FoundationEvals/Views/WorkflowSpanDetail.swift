import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkflowSpanDetail: View {
    let node: WorkflowTraceNode
    let result: EvaluationSampleResult
    let run: EvaluationRun
    let trace: WorkflowTracePresentation
    @State private var tab = DetailTab.details
    @State private var exportDocument = JSONDocument()
    @State private var isExporting = false
    @State private var exportError: String?

    private enum DetailTab: String, CaseIterable {
        case details = "Details"
        case content = "Input / Output"
        case transcript = "Transcript"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: node.symbol).foregroundStyle(node.color)
                    Text(node.title).font(.headline).textSelection(.enabled)
                        .accessibilityIdentifier("Selected span title")
                        .id(node.id)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .contain)
                HStack {
                    Text(node.outcome.capitalized).foregroundStyle(node.color)
                    Spacer()
                    Text(WorkflowTracePresentation.duration(node.durationMilliseconds)).monospacedDigit()
                }
                .font(.caption.weight(.medium))
                .accessibilityElement(children: .contain)
                Picker("Span detail", selection: $tab) {
                    ForEach(DetailTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case .details: details
                    case .content: content
                    case .transcript: transcriptContent
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(node.id)
        }
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Span details")
        .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .json,
            defaultFilename: "\(result.id.uuidString)-transcript.json") { outcome in
            if case .failure(let error) = outcome { exportError = error.localizedDescription }
        }
        .alert("Could not export transcript", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) { Button("OK") { exportError = nil } } message: { Text(exportError ?? "") }
    }

    private var details: some View {
        Group {
            if let error = node.errorMessage { TraceEvidenceBlock(title: "Error", text: error, color: .red) }
            detailSection("TIMING") {
                TraceDetailMetric(label: "Start", value: offset(node.startMilliseconds))
                TraceDetailMetric(label: "End", value: offset(node.endMilliseconds))
                TraceDetailMetric(label: "Duration", value: WorkflowTracePresentation.duration(node.durationMilliseconds))
                if let duration = node.durationMilliseconds, node.startMilliseconds != nil {
                    TraceDetailMetric(label: "Of workflow", value: (duration / trace.extentMilliseconds)
                        .formatted(.percent.precision(.fractionLength(1))))
                }
                Text(node.startMilliseconds == nil ? "Timeline placement is unavailable for this span."
                    : "Elapsed time measured by the app on a monotonic clock. Nested durations overlap and must not be added together.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let usage = evidenceUsage {
                detailSection(node.kind == .sample ? "SUBJECT SESSION USAGE" : "TOKEN USAGE") {
                    TraceDetailMetric(label: "Input", value: usage.inputTokens.formatted())
                    TraceDetailMetric(label: "Cached input", value: usage.cachedInputTokens.formatted())
                    TraceDetailMetric(label: "Output", value: usage.outputTokens.formatted())
                    TraceDetailMetric(label: "Reasoning", value: usage.reasoningTokens.formatted())
                    Text("Framework-reported usage. Cached input is part of input; reasoning is part of output.")
                        .font(.caption).foregroundStyle(.secondary)
                    if node.kind == .sample {
                        Text("Includes recorded setup turns in the subject session. AI judge usage is separate.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let judgeUsage = result.judgeUsage {
                            TraceDetailMetric(label: "AI judge tokens", value: judgeUsage.totalTokens.formatted())
                        }
                    }
                }
            } else if node.kind == .generation || node.kind == .judge {
                Text("Per-span token usage was not recorded.").font(.caption).foregroundStyle(.secondary)
            }
            if let first = firstContentMilliseconds {
                detailSection("STREAMING") {
                    TraceDetailMetric(label: "First visible content", value: WorkflowTracePresentation.duration(first))
                    Text("App-observed time to visible content during generation; not a per-token timestamp.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            detailSection("METADATA") {
                TraceDetailMetric(label: "Operation", value: operation)
                if node.kind == .sample || node.kind == .generation || node.kind == .judge {
                    TraceDetailMetric(label: "Model", value: run.execution?.modelDisplayName ?? run.environment.model)
                }
                if let parent = trace.nodes.first(where: { $0.id == node.parentID }) {
                    TraceDetailMetric(label: "Parent", value: parent.title)
                }
                ForEach(node.metadata.keys.filter { !Self.usageKeys.contains($0) }.sorted(), id: \.self) { key in
                    TraceDetailMetric(label: Self.metadataLabel(key), value: node.metadata[key] ?? "")
                }
                TraceDetailMetric(label: "Span ID", value: node.id)
                TraceDetailMetric(label: "Sample ID", value: result.id.uuidString)
            }
            if node.kind == .sample {
                detailSection("RUN CONTEXT") {
                    TraceDetailMetric(label: "Version", value: run.suiteVersion)
                    TraceDetailMetric(label: "Scoring", value: run.scoringMode.title)
                    TraceDetailMetric(label: "Repetition", value: String(result.repetition))
                    TraceDetailMetric(label: "System", value: run.environment.operatingSystem)
                    TraceDetailMetric(label: "Locale", value: run.environment.locale)
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if node.kind == .httpRequest {
            Text("Request metadata is available in Details. Headers and transport bodies are not captured by the workflow trace.")
                .font(.callout).foregroundStyle(.secondary)
        } else if node.kind == .tool {
            toolContent
        } else if node.metadata["turnID"] != nil {
            if let turn = result.featureTrace?.conversation?.turns.first(where: { $0.id.uuidString == node.metadata["turnID"] }) {
                TraceEvidenceBlock(title: "Input", text: node.kind == .preparation ? turn.prompt : turn.effectivePrompt ?? turn.prompt)
                TraceEvidenceBlock(title: "Output", text: node.kind == .preparation ? turn.effectivePrompt ?? "No prepared input recorded" : turn.response ?? "No output recorded")
                if let error = turn.errorMessage { TraceEvidenceBlock(title: "Error", text: error, color: .red) }
            } else { unavailableContent }
        } else if node.metadata["role"] == "judge" {
            if let index = node.metadata["judgeAttempt"].flatMap(Int.init),
               let attempts = result.judgeTrace?.attempts, attempts.indices.contains(index - 1) {
                TraceEvidenceBlock(title: "Input", text: attempts[index - 1].prompt)
                TraceEvidenceBlock(title: "Output", text: attempts[index - 1].rawResponse ?? "No output recorded")
                if let error = attempts[index - 1].validationError {
                    TraceEvidenceBlock(title: "Validation", text: error, color: .orange)
                }
            } else { unavailableContent }
        } else if node.kind == .judge {
            if let judge = result.judgeTrace {
                TraceEvidenceBlock(title: "Instructions", text: judge.instructions)
                TraceEvidenceBlock(title: "Input", text: judge.prompt)
                TraceEvidenceBlock(title: "Output", text: judge.rawResponse ?? "No output recorded")
                if let error = judge.validationError { TraceEvidenceBlock(title: "Validation", text: error, color: .orange) }
            } else { unavailableContent }
        } else if node.kind == .scoring {
            TraceEvidenceBlock(title: "Response scored", text: result.response)
            TraceEvidenceBlock(title: "Expected / reference", text: result.expected.isEmpty ? "None" : result.expected)
            TraceEvidenceBlock(title: "Verdict", text: result.rationale ?? result.status.rawValue.capitalized)
            if let assertions = result.fieldAssertionResults, !assertions.isEmpty {
                FieldAssertionEvidenceSection(results: assertions)
            }
        } else if node.kind == .preparation {
            preparationContent
        } else {
            TraceEvidenceBlock(title: "Input", text: result.effectivePrompt ?? result.prompt)
            TraceEvidenceBlock(title: "Output", text: result.response.isEmpty ? "No output recorded" : result.response)
            if let reasoning = result.reasoningText, !reasoning.isEmpty {
                TraceEvidenceBlock(title: "Returned reasoning", text: reasoning)
            }
        }
    }

    @ViewBuilder private var toolContent: some View {
        if node.metadata["toolSource"] == "reference" {
            Text("Reference queries and returned passages are intentionally omitted from the saved tool trace.")
                .font(.callout).foregroundStyle(.secondary)
        } else if let call = result.featureTrace?.customToolCalls.first(where: { $0.id.uuidString == node.metadata["callID"] }) {
            TraceEvidenceBlock(title: "Arguments", text: call.argumentsJSON)
            TraceEvidenceBlock(title: "Output", text: call.output ?? "No output recorded")
            if let error = call.errorDescription { TraceEvidenceBlock(title: "Error", text: error, color: .red) }
        } else if let call = result.featureTrace?.builtinToolCalls?.first(where: { $0.id == node.metadata["callID"] }) {
            TraceEvidenceBlock(title: "Arguments", text: call.argumentsJSON)
            TraceEvidenceBlock(title: "Output", text: call.output ?? "No output recorded")
        } else { unavailableContent }
    }

    @ViewBuilder private var transcriptContent: some View {
        if let transcript = result.featureTrace?.transcript {
            Text("SAMPLE TRANSCRIPT").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text("The recorded Foundation Models conversation for this sample. It is shared context, not the selected span’s private internal trace.")
                .font(.caption).foregroundStyle(.secondary)
            TraceDetailMetric(label: "Entries", value: transcript.entryCount.formatted())
            if let count = transcript.encodedByteCount { TraceDetailMetric(label: "Size", value: ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)) }
            if let data = transcript.exportData {
                Button("Export Transcript JSON…", systemImage: "square.and.arrow.up") {
                    exportDocument.data = data
                    isExporting = true
                }
                TraceEvidenceBlock(title: "Recorded JSON", text: String(decoding: data.prefix(16_000), as: UTF8.self))
                if data.count > 16_000 {
                    Text("Preview limited to 16 KB. Export contains the complete saved transcript.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(transcript.omissionReason ?? "Transcript content was not saved.").font(.callout).foregroundStyle(.secondary)
            }
            Text("Transcript export and Apple feedback attachment tools are also available in Report.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("No Foundation Models transcript was saved for this sample.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var unavailableContent: some View {
        Text("No input or output was recorded for this span.").font(.callout).foregroundStyle(.secondary)
    }

    private var isFinalGeneration: Bool {
        node.kind == .generation && (node.metadata["role"] == "evaluation" || node.metadata["role"] == nil)
    }

    private var firstContentMilliseconds: Double? {
        guard node.kind == .generation else { return nil }
        return node.metadata["firstContentMilliseconds"].flatMap(Double.init)
            ?? (isFinalGeneration ? result.featureTrace?.firstContentMilliseconds : nil)
    }

    @ViewBuilder private var preparationContent: some View {
        switch node.metadata["operation"] {
        case "sessionSetup":
            TraceEvidenceBlock(title: "Instructions", text: run.instructions.isEmpty ? "None" : run.instructions)
            TraceEvidenceBlock(title: "Configured tools", text: run.execution?.toolNames.joined(separator: "\n") ?? "Not recorded")
        case "restoreHistory":
            if let planned = run.plannedCases?.first(where: { $0.id == result.caseID }) {
                TraceEvidenceBlock(title: "Restored transcript", text: planned.conversation.restoredTranscriptJSON ?? "No restored transcript supplied")
            } else { unavailableContent }
        case "applyHistoryPolicy", "prewarm":
            Text("Operation settings and measured timing are available in Details. No separate input or output was captured for this operation.")
                .font(.callout).foregroundStyle(.secondary)
        default:
            TraceEvidenceBlock(title: "Instructions", text: run.instructions.isEmpty ? "None" : run.instructions)
            TraceEvidenceBlock(title: "Prompt", text: result.prompt)
            TraceEvidenceBlock(title: "Prepared input", text: result.effectivePrompt ?? "No separate prepared input recorded")
        }
    }

    private var evidenceUsage: EvaluationUsage? {
        node.usage(in: result, measured: trace.hasMeasuredOffsets)
    }

    private var operation: String {
        switch node.kind {
        case .sample: "Evaluation sample"
        case .preparation: "Input and session preparation"
        case .generation: "Foundation Models generation"
        case .scoring: "Response scoring"
        case .judge: "AI rubric evaluation"
        case .tool: "Tool execution"
        case .httpRequest: "HTTP tool request"
        }
    }

    private func offset(_ value: Double?) -> String {
        value == nil ? "Not recorded" : "+\(WorkflowTracePresentation.duration(value))"
    }

    private func detailSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
            content()
        }
    }

    private static let usageKeys: Set<String> = ["inputTokens", "cachedInputTokens", "outputTokens", "reasoningTokens", "usageSource"]
    private static func metadataLabel(_ key: String) -> String {
        switch key {
        case "method": "Method"
        case "endpoint": "Endpoint"
        case "statusCode": "Status code"
        case "requestBytes": "Request bytes"
        case "responseBytes": "Response bytes"
        case "callID": "Call ID"
        case "toolName": "Tool"
        case "toolSource": "Tool source"
        case "callIndex": "Call index"
        case "streaming": "Streaming"
        case "role": "Role"
        case "resultStatus": "Evaluation outcome"
        default: key.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
        }
    }
}

private struct TraceDetailMetric: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.caption).monospacedDigit()
        .accessibilityElement(children: .contain)
    }
}

private struct TraceEvidenceBlock: View {
    let title: String
    let text: String
    var color: Color = .secondary
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(color)
                Spacer()
                Button("Copy \(title)", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            Text(expanded ? text : String(text.prefix(4_000)))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.30), in: .rect(cornerRadius: 6))
            if text.count > 4_000 {
                Button(expanded ? "Show less" : "Show all \(text.count.formatted()) characters") { expanded.toggle() }
                    .font(.caption).buttonStyle(.link)
            }
        }
    }
}
