import SwiftUI
import UniformTypeIdentifiers

struct CoreAIModelControls: View {
    @Binding var configuration: EvaluationCoreAIConfiguration
    let status: CoreAIModelControlStatus
    let onLoad: @MainActor @Sendable () async -> Void
    @State private var isChoosingResources = false
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Core AI model")
                .font(.headline)

            Text("Choose the resource folder produced by an Apple coreai-models export. It must contain metadata.json, the model asset, and its tokenizer resources.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                TextField("Model resource folder", text: $configuration.resourcesPath)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("Core AI resource folder")
                    .onSubmit(loadModel)

                Button {
                    isChoosingResources = true
                } label: {
                    Label("Choose Folder…", systemImage: "folder")
                }
                .accessibilityIdentifier("Choose Core AI resource folder")

                if configuration.hasResources {
                    Button("Clear") {
                        configuration.clearResources()
                        importError = nil
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    loadModel()
                } label: {
                    Label(
                        status.isLoaded ? "Reload Model" : "Load Model",
                        systemImage: "arrow.down.circle"
                    )
                }
                .disabled(!configuration.hasResources || status == .loading)
                .accessibilityIdentifier("Load Core AI model")

                CoreAIModelStatusView(status: status)
            }

            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("Core AI resource folder error")
            }

            Text("The app validates and loads this model before reporting its context window or capabilities. Loading can take time and may use substantial memory.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fileImporter(
            isPresented: $isChoosingResources,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    try configuration.selectResources(at: url)
                    importError = nil
                    loadModel()
                } catch {
                    importError = error.localizedDescription
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
    }

    /// Starts an unstructured task to invoke the host asynchronous model-loading action; this view retains no cancellation handle.
    private func loadModel() {
        Task {
            await onLoad()
        }
    }
}

private struct CoreAIModelStatusView: View {
    let status: CoreAIModelControlStatus

    var body: some View {
        switch status {
        case .unconfigured:
            Text("Choose a model resource folder.")
                .foregroundStyle(.secondary)
        case .readyToLoad:
            Text("Load the model to inspect its capabilities and context window.")
                .foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading and validating the model…")
            }
            .foregroundStyle(.secondary)
        case .loaded(let descriptor):
            VStack(alignment: .leading, spacing: 2) {
                Text("Loaded \(descriptor.modelName) · \(descriptor.contextSize.formatted()) token context")
                Text(
                    "Capabilities: \(descriptor.capabilityNames.isEmpty ? "none reported" : descriptor.capabilityNames.formatted())"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let bytes = descriptor.estimatedSizeOnDiskBytes {
                    Text("Model asset: \(bytes.formatted(.byteCount(style: .file)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}

private extension CoreAIModelControlStatus {
    var isLoaded: Bool {
        if case .loaded = self {
            true
        } else {
            false
        }
    }
}

private extension CoreAIModelDescriptor {
    var capabilityNames: [String] {
        var names: [String] = []
        if supportsVision { names.append("vision") }
        if supportsGuidedGeneration { names.append("guided generation") }
        if supportsReasoning { names.append("reasoning") }
        if supportsToolCalling { names.append("tool calling") }
        return names
    }
}
