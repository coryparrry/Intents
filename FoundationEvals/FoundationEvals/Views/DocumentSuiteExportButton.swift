import SwiftUI
import UniformTypeIdentifiers

struct DocumentSuiteExportButton: View {
    var suite: EvaluationSuite
    var telemetry: TelemetryController?
    @State private var controller = TelemetryFileExportController()
    @State private var document = JSONDocument()
    @State private var exporting = false
    @State private var error: String?

    var body: some View {
        Button("Export document suite and source…", systemImage: "square.and.arrow.up") {
            do {
                document.data = try controller.prepare(.suiteExport, telemetry: telemetry) { try EvaluationDocumentArchive.data(for: suite) }
                exporting = true
            } catch { self.error = error.localizedDescription }
        }
        .help("Includes questions, reference answers, case criteria, and retained source text. Local model and judge bindings are omitted.")
        .fileExporter(isPresented: $exporting, document: document, contentTypes: [.json], defaultFilename: "Document suite", onCompletion: { result in
            controller.complete(result)
            if case .failure(let failure) = result { error = failure.localizedDescription }
        }, onCancellation: { controller.cancel() })
        .onDisappear { controller.cancel() }
        .alert("Could not export document suite", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}
