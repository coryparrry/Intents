import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TranscriptFeedbackSection: View {
    let trace: EvaluationTranscriptTrace
    let configuration: EvaluationModelConfiguration?
    let caseName: String
    let repetition: Int

    @State private var preview = TranscriptPreview.loading
    @State private var hasCopiedTranscript = false
    @State private var sentiment: EvaluationFeedbackSentiment?
    @State private var selectedIssues: Set<EvaluationFeedbackIssueCategory> = []
    @State private var issueExplanations: [EvaluationFeedbackIssueCategory: String] = [:]
    @State private var desiredOutput = EvaluationFeedbackDesiredOutputDraft()
    @State private var exportDocument = JSONDocument()
    @State private var exportFilename = "transcript.json"
    @State private var isExporting = false
    @State private var isPreparingFeedback = false
    @State private var exportError: String?

    var body: some View {
        DisclosureGroup("Foundation Models transcript and feedback") {
            VStack(alignment: .leading, spacing: 14) {
                TranscriptCaptureSummary(trace: trace)

                Label(
                    "The transcript may contain complete prompts, responses, reasoning, tool calls and outputs, and reference or attachment content supplied to the model. Review it before exporting.",
                    systemImage: "exclamationmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if let omissionReason = trace.omissionReason {
                    Label(omissionReason, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TranscriptPreviewBlock(preview: preview)

                    HStack(spacing: 10) {
                        Button(
                            hasCopiedTranscript ? "Copied" : "Copy Transcript JSON",
                            systemImage: hasCopiedTranscript ? "checkmark" : "doc.on.doc"
                        ) {
                            copyTranscript()
                        }
                        Button("Export Transcript JSON…", systemImage: "square.and.arrow.up") {
                            exportTranscript()
                        }
                    }
                    .buttonStyle(.bordered)

                    Divider()

                    FeedbackDraftForm(
                        sentiment: $sentiment,
                        selectedIssues: $selectedIssues,
                        issueExplanations: $issueExplanations,
                        desiredOutput: $desiredOutput
                    )

                    if configuration == nil {
                        Label(
                            "This legacy run does not record the model configuration needed to create a provider-correct Apple feedback attachment.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Button(
                            isPreparingFeedback ? "Preparing Feedback…" : "Export Feedback Attachment…",
                            systemImage: "doc.badge.arrow.up"
                        ) {
                            Task { await exportFeedbackAttachment() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canExportFeedback || isPreparingFeedback)

                        if isPreparingFeedback {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Text("This saves Apple's JSON attachment for Feedback Assistant. It does not submit feedback.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 10)
        }
        .font(.callout)
        .task {
            let trace = trace
            preview = await Task.detached(priority: .utility) {
                TranscriptPreview(trace: trace)
            }.value
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result {
                exportError = error.localizedDescription
            }
        }
        .alert(
            "Could not export transcript data",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var canExportFeedback: Bool {
        configuration != nil
            && trace.exportData != nil
            && desiredOutput.validationIssue == nil
            && (sentiment != nil || !selectedIssues.isEmpty || desiredOutput.hasDesiredOutput)
    }

    private var feedbackIssues: [EvaluationFeedbackIssueDraft] {
        EvaluationFeedbackIssueCategory.allCases.compactMap { category in
            guard selectedIssues.contains(category) else { return nil }
            let explanation = issueExplanations[category]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return EvaluationFeedbackIssueDraft(
                category: category,
                explanation: explanation.flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }

    private var safeBaseFilename: String {
        let safeName = caseName.replacingOccurrences(
            of: "[^A-Za-z0-9_-]+",
            with: "-",
            options: .regularExpression
        )
        return "\(safeName)-repetition-\(repetition)"
    }

    /// Copies formatted transcript JSON to the general pasteboard and marks success, exposing serialization failures as export errors.
    private func copyTranscript() {
        do {
            let text = String(decoding: try trace.formattedJSONData(), as: UTF8.self)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            hasCopiedTranscript = true
        } catch {
            exportError = error.localizedDescription
        }
    }

    /// Prepares the captured transcript bytes and filename for the file exporter, or exposes the saved omission reason when unavailable.
    private func exportTranscript() {
        guard let data = trace.exportData else {
            exportError = trace.omissionReason ?? "The transcript was not captured."
            return
        }
        exportDocument = JSONDocument(data: data)
        exportFilename = "\(safeBaseFilename)-transcript.json"
        isExporting = true
    }

    /// Validates model identity and desired output, then asynchronously prepares a feedback attachment before opening the file exporter.
    /// The caller owns the task; this method clears its preparing flag after generation and displays thrown errors, including cancellation.
    private func exportFeedbackAttachment() async {
        guard let configuration else {
            exportError = "The run does not contain the model configuration required to preserve model identity."
            return
        }
        isPreparingFeedback = true
        defer { isPreparingFeedback = false }
        do {
            if let issue = desiredOutput.validationIssue {
                throw EvaluationFeedbackDesiredOutputError.invalid(issue)
            }
            let data = try await trace.feedbackAttachment(
                configuration: configuration,
                sentiment: sentiment,
                issues: feedbackIssues,
                desiredOutput: desiredOutput
            )
            exportDocument = JSONDocument(data: data)
            exportFilename = "\(safeBaseFilename)-apple-feedback.json"
            isExporting = true
        } catch {
            exportError = error.localizedDescription
        }
    }


}

private enum EvaluationFeedbackDesiredOutputError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

private struct TranscriptCaptureSummary: View {
    let trace: EvaluationTranscriptTrace

    var body: some View {
        HStack(spacing: 10) {
            Label(
                trace.outcome == .success ? "Successful response transcript" : "Failed response transcript",
                systemImage: trace.outcome == .success ? "checkmark.circle" : "exclamationmark.circle"
            )
            Spacer()
            Text("\(trace.entryCount) entries")
            if let byteCount = trace.encodedByteCount {
                Text(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))
            }
        }
        .foregroundStyle(.secondary)
    }
}

private struct TranscriptPreviewBlock: View {
    let preview: TranscriptPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Transcript JSON preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if preview.isTruncated {
                    Text("Preview limited; copy or export includes the full transcript")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView([.horizontal, .vertical]) {
                Text(preview.text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 90, maxHeight: 220)
            .padding(10)
            .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.14))
            }
        }
    }
}

private struct FeedbackDraftForm: View {
    @Binding var sentiment: EvaluationFeedbackSentiment?
    @Binding var selectedIssues: Set<EvaluationFeedbackIssueCategory>
    @Binding var issueExplanations: [EvaluationFeedbackIssueCategory: String]
    @Binding var desiredOutput: EvaluationFeedbackDesiredOutputDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prepare Apple feedback attachment")
                .font(.headline)

            Picker("Overall sentiment", selection: $sentiment) {
                Text("Not specified").tag(nil as EvaluationFeedbackSentiment?)
                ForEach(EvaluationFeedbackSentiment.allCases) { item in
                    Text(item.title).tag(Optional(item))
                }
            }
            .accessibilitySelectionActions(
                [Optional<EvaluationFeedbackSentiment>.none]
                    + EvaluationFeedbackSentiment.allCases.map { Optional($0) },
                selection: $sentiment,
                title: { $0?.title ?? "Not specified" }
            )
            .pickerStyle(.menu)
            .frame(maxWidth: 320, alignment: .leading)

            VStack(alignment: .leading, spacing: 9) {
                Text("Issues")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(EvaluationFeedbackIssueCategory.allCases) { category in
                    VStack(alignment: .leading, spacing: 5) {
                        Toggle(category.title, isOn: selectionBinding(for: category))
                        if selectedIssues.contains(category) {
                            TextField("Optional explanation", text: explanationBinding(for: category))
                                .textFieldStyle(.roundedBorder)
                                .padding(.leading, 20)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Picker("Desired output", selection: $desiredOutput.mode) {
                    ForEach(EvaluationFeedbackDesiredOutputMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .accessibilitySelectionActions(
                    EvaluationFeedbackDesiredOutputMode.allCases,
                    selection: $desiredOutput.mode,
                    title: \.title
                )
                .pickerStyle(.menu)
                .frame(maxWidth: 320, alignment: .leading)

                switch desiredOutput.mode {
                case .none:
                    Text("Optionally include the response the model should have produced.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .responseText:
                    FeedbackDesiredOutputEditor(
                        title: "Desired response text",
                        text: $desiredOutput.responseText
                    )
                case .generatedContentJSON:
                    FeedbackDesiredOutputEditor(
                        title: "Desired generated content JSON",
                        text: $desiredOutput.generatedContentJSON,
                        monospaced: true
                    )
                case .transcriptJSON:
                    FeedbackDesiredOutputEditor(
                        title: "Transcript JSON containing one desired response",
                        text: $desiredOutput.transcriptJSON,
                        monospaced: true
                    )
                    Text("Paste a complete Foundation Models Transcript JSON value containing exactly one response entry. Other entry types may be included; the response entry is used as the desired output.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let issue = desiredOutput.validationIssue {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if desiredOutput.mode != .none {
                    Text("\(activeDesiredOutputCharacterCount.formatted()) of \(EvaluationFeedbackDesiredOutputDraft.maximumCharacters.formatted()) characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var activeDesiredOutputCharacterCount: Int {
        switch desiredOutput.mode {
        case .none: 0
        case .responseText: desiredOutput.responseText.count
        case .generatedContentJSON: desiredOutput.generatedContentJSON.count
        case .transcriptJSON: desiredOutput.transcriptJSON.count
        }
    }

    /// Binds issue-category membership and removes its explanation when the category is deselected.
    private func selectionBinding(for category: EvaluationFeedbackIssueCategory) -> Binding<Bool> {
        Binding(
            get: { selectedIssues.contains(category) },
            set: { selected in
                if selected {
                    selectedIssues.insert(category)
                } else {
                    selectedIssues.remove(category)
                    issueExplanations.removeValue(forKey: category)
                }
            }
        )
    }

    /// Binds a category explanation with an empty-string fallback for categories without saved text.
    private func explanationBinding(for category: EvaluationFeedbackIssueCategory) -> Binding<String> {
        Binding(
            get: { issueExplanations[category, default: ""] },
            set: { issueExplanations[category] = $0 }
        )
    }
}

private struct FeedbackDesiredOutputEditor: View {
    let title: LocalizedStringResource
    @Binding var text: String
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(monospaced ? .body.monospaced() : .body)
                .frame(minHeight: 70, maxHeight: 150)
                .padding(5)
                .background(.background, in: .rect(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.secondary.opacity(0.18))
                }
        }
    }
}

private struct TranscriptPreview: Sendable {
    static let maximumCharacters = 40_000
    static let loading = Self(text: "Loading transcript…", isTruncated: false)

    var text: String
    var isTruncated: Bool

    /// Formats a transcript preview capped at the display character limit, recording truncation or a readable serialization failure.
    init(trace: EvaluationTranscriptTrace) {
        do {
            let fullText = String(decoding: try trace.formattedJSONData(), as: UTF8.self)
            isTruncated = fullText.count > Self.maximumCharacters
            text = String(fullText.prefix(Self.maximumCharacters))
        } catch {
            text = "The transcript could not be displayed: \(error.localizedDescription)"
            isTruncated = false
        }
    }

    /// Creates a preview with precomputed text and truncation state for placeholder values.
    private init(text: String, isTruncated: Bool) {
        self.text = text
        self.isTruncated = isTruncated
    }
}
