import SwiftUI
import UniformTypeIdentifiers

struct CaseImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: EvaluationStore
    @State private var isChoosingFile = false
    @State private var filename = ""
    @State private var fileSelection = CaseImportFileSelection()
    @State private var format = EvaluationCaseImportFormat.csv
    @State private var columns: [String] = []
    @State private var nameColumn: String?
    @State private var promptColumn = ""
    @State private var expectedColumn: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Import cases").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text("Map UTF-8 CSV or JSONL columns before changing the suite.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose File…") {
                    clearSelection()
                    isChoosingFile = true
                }
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if fileSelection.data != nil {
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

                        if let preview = fileSelection.preview {
                            if preview.rows.isEmpty {
                                WorkspaceEmptyState(symbol: "tablecells", title: "No importable rows", detail: "Check the column mapping and the issues below.")
                            } else {
                                Table(preview.rows) {
                                    TableColumn("Line") { Text($0.sourceLine.formatted()) }.width(45)
                                    TableColumn("Name", value: \.name)
                                    TableColumn("Prompt", value: \.prompt)
                                    TableColumn("Expected", value: \.expected)
                                }
                                .frame(height: 190)
                            }
                            ForEach(preview.issues) { issue in
                                WorkspaceNotice(.warning, message: issue.line.map { "Line \($0): \(issue.message)" } ?? issue.message)
                            }
                        }
                    } else {
                        WorkspaceEmptyState(symbol: "tablecells", title: "Choose a case file",
                                            detail: "Preview your prompts and expected answers before adding them to the suite.")
                            .workspaceSurface()
                    }

                    if let errorMessage {
                        WorkspaceNotice(.failure, message: errorMessage)
                    }

                }
                .padding(24)
            }
            .background(WorkspaceStyle.canvas)
            .accessibilityIdentifier("Case import preview")
            Divider()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Import \(importCount) Cases") { importCases() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(fileSelection.preview?.canImport != true || importCount == 0)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 760, height: 620)
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: [.commaSeparatedText, .json, .plainText],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                try fileSelection.load(at: url, maximumBytes: EvaluationStore.maximumTextFileBytes)
                filename = url.lastPathComponent
                format = url.pathExtension.lowercased() == "csv" ? .csv : .jsonLines
                prepareColumns()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func clearSelection() {
        fileSelection.clear()
        filename = ""
        columns = []
        nameColumn = nil
        promptColumn = ""
        expectedColumn = nil
        errorMessage = nil
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
        guard let data = fileSelection.data else { return }
        do {
            columns = try EvaluationCaseImporter.columns(in: data, format: format)
            promptColumn = columns.first(where: { $0.localizedCaseInsensitiveCompare("prompt") == .orderedSame })
                ?? columns.first ?? ""
            nameColumn = columns.first(where: { $0.localizedCaseInsensitiveCompare("name") == .orderedSame })
            expectedColumn = columns.first(where: { $0.localizedCaseInsensitiveCompare("expected") == .orderedSame })
            updatePreview()
        } catch {
            fileSelection.preview = nil
            errorMessage = error.localizedDescription
        }
    }

    private func updatePreview() {
        guard let data = fileSelection.data, !promptColumn.isEmpty else { return }
        do {
            fileSelection.preview = try EvaluationCaseImporter.preview(
                data: data,
                format: format,
                mapping: .init(nameColumn: nameColumn, promptColumn: promptColumn, expectedColumn: expectedColumn)
            )
            errorMessage = nil
        } catch {
            fileSelection.preview = nil
            errorMessage = error.localizedDescription
        }
    }

    private var importCount: Int {
        min(fileSelection.preview?.totalValidRowCount ?? 0, store.remainingCaseImportCapacity)
    }

    private func importCases() {
        guard let data = fileSelection.data else { return }
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

struct CaseImportFileSelection {
    var data: Data?
    var preview: EvaluationCaseImportPreview?

    mutating func clear() {
        data = nil
        preview = nil
    }

    mutating func load(at url: URL, maximumBytes: Int) throws {
        clear()
        data = try EvaluationAttachmentStorage.readCaseImportFile(at: url, maximumBytes: maximumBytes)
    }
}
