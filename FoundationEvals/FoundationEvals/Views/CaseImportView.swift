import SwiftUI
import UniformTypeIdentifiers

struct CaseImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: EvaluationStore
    @State private var isChoosingFile = false
    @State private var filename = ""
    @State private var data: Data?
    @State private var format = EvaluationCaseImportFormat.csv
    @State private var columns: [String] = []
    @State private var nameColumn: String?
    @State private var promptColumn = ""
    @State private var expectedColumn: String?
    @State private var preview: EvaluationCaseImportPreview?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Import cases").font(.title2.bold())
                    Text("Map UTF-8 CSV or JSONL columns before changing the suite.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose File…") { isChoosingFile = true }
            }

            if data != nil {
                LabeledContent("File", value: filename)
                Picker("Format", selection: $format) {
                    Text("CSV").tag(EvaluationCaseImportFormat.csv)
                    Text("JSON Lines").tag(EvaluationCaseImportFormat.jsonLines)
                }
                .pickerStyle(.segmented)
                .onChange(of: format) { _, _ in prepareColumns() }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow { Text("Name"); optionalColumnPicker(selection: $nameColumn) }
                    GridRow { Text("Prompt"); requiredColumnPicker(selection: $promptColumn) }
                    GridRow { Text("Expected"); optionalColumnPicker(selection: $expectedColumn) }
                }
                .onChange(of: nameColumn) { _, _ in updatePreview() }
                .onChange(of: promptColumn) { _, _ in updatePreview() }
                .onChange(of: expectedColumn) { _, _ in updatePreview() }

                if let preview {
                    if preview.rows.isEmpty {
                        ContentUnavailableView("No importable rows", systemImage: "exclamationmark.tablecells")
                    } else {
                        Table(preview.rows) {
                            TableColumn("Line") { Text($0.sourceLine.formatted()) }.width(45)
                            TableColumn("Name", value: \.name)
                            TableColumn("Prompt", value: \.prompt)
                            TableColumn("Expected", value: \.expected)
                        }
                        .frame(minHeight: 190)
                    }
                    ForEach(preview.issues) { issue in
                        Label(
                            issue.line.map { "Line \($0): \(issue.message)" } ?? issue.message,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Choose a case file",
                    systemImage: "tablecells",
                    description: Text("Nothing is imported until the preview validates.")
                )
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Import \(importCount) Cases") { importCases() }
                    .buttonStyle(.borderedProminent)
                    .disabled(preview?.canImport != true || importCount == 0)
            }
        }
        .padding(22)
        .frame(width: 760, height: 590)
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: [.commaSeparatedText, .json, .plainText],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                data = try EvaluationAttachmentStorage.readCaseImportFile(
                    at: url,
                    maximumBytes: EvaluationStore.maximumTextFileBytes
                )
                filename = url.lastPathComponent
                format = url.pathExtension.lowercased() == "csv" ? .csv : .jsonLines
                prepareColumns()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func optionalColumnPicker(selection: Binding<String?>) -> some View {
        Picker("Column", selection: selection) {
            Text("Not mapped").tag(String?.none)
            ForEach(columns, id: \.self) { Text($0).tag(Optional($0)) }
        }
        .labelsHidden()
        .frame(width: 240)
    }

    private func requiredColumnPicker(selection: Binding<String>) -> some View {
        Picker("Column", selection: selection) {
            ForEach(columns, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .frame(width: 240)
    }

    private func prepareColumns() {
        guard let data else { return }
        do {
            columns = try EvaluationCaseImporter.columns(in: data, format: format)
            promptColumn = columns.first(where: { $0.localizedCaseInsensitiveCompare("prompt") == .orderedSame })
                ?? columns.first ?? ""
            nameColumn = columns.first(where: { $0.localizedCaseInsensitiveCompare("name") == .orderedSame })
            expectedColumn = columns.first(where: { $0.localizedCaseInsensitiveCompare("expected") == .orderedSame })
            updatePreview()
        } catch {
            preview = nil
            errorMessage = error.localizedDescription
        }
    }

    private func updatePreview() {
        guard let data, !promptColumn.isEmpty else { return }
        do {
            preview = try EvaluationCaseImporter.preview(
                data: data,
                format: format,
                mapping: .init(nameColumn: nameColumn, promptColumn: promptColumn, expectedColumn: expectedColumn)
            )
            errorMessage = nil
        } catch {
            preview = nil
            errorMessage = error.localizedDescription
        }
    }

    private var importCount: Int {
        min(preview?.totalValidRowCount ?? 0, store.remainingCaseImportCapacity)
    }

    private func importCases() {
        guard let data else { return }
        do {
            let remaining = store.remainingCaseImportCapacity
            guard remaining > 0 else { throw EvaluationCaseImportError.tooManyRows(maximum: 0) }
            let imported = try EvaluationCaseImporter.cases(
                data: data,
                format: format,
                mapping: .init(nameColumn: nameColumn, promptColumn: promptColumn, expectedColumn: expectedColumn),
                maximumCases: remaining
            )
            try store.appendImportedCases(imported)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
