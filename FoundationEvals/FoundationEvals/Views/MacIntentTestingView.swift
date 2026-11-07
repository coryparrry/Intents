import MacIntentTesting
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MacIntentTestingView: View {
    @Bindable var model: MacIntentTestingStore
    @AppStorage("appIntentTesting.mode") private var mode = "siri"
    @State private var choosingApp = false
    @State private var showsBuildDetails = false
    @State private var showsSupportedTypes = false

    var body: some View {
        Group {
            if mode == "siri" {
                SiriStudioView(native: model, studio: model.siri, catalog: model.catalog,
                    chooseApp: { choosingApp = true }, showDirectAction: { mode = "direct" })
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        WorkspacePageHeader("App Intent Testing", subtitle: "Test an action from a built macOS app.")
                        Picker("Testing mode", selection: $mode) {
                            Text("Direct Action").tag("direct")
                            Text("Siri Studio").tag("siri")
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        .accessibilityIdentifier("app-intent-testing-mode")
                        .disabled(model.isRunning || model.siri.isBusy)
                        appSelection
                        configurationForm
                    }.workspacePage()
                }.accessibilityIdentifier("App Intent steps")
            }
        }
        .fileImporter(isPresented: $choosingApp, allowedContentTypes: [.applicationBundle]) { result in
            do {
                let url = try result.get()
                try model.siri.save()
                model.load(appURL: url)
            } catch { model.reportSelectionError(error) }
        }
        .onChange(of: model.catalog?.productIdentity, initial: true) { _, _ in
            // The store also tracks the catalog independently of which mode is visible.
            model.siri.load(model.catalog)
        }
    }

    /// Selects one built app for both native test modes.
    private var appSelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if mode == "direct" {
                Text("Install and launch the app normally once to register it, then quit it before choosing its build.")
            } else if model.catalog == nil {
                Text("Choose the Mac app you want to test. We’ll check the setup for you.")
            }
            Button(model.catalog == nil ? "Choose built macOS app…" : "Change app…") { choosingApp = true }
                .accessibilityLabel("Choose built macOS app…")
                .buttonStyle(.bordered)
                .disabled(model.isRunning || model.siri.isBusy)
            if model.isLoading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Inspecting built app…")
                    Button("Cancel") { model.cancel() }
                }
            }
            if let catalog = model.catalog {
                HStack {
                    Text(catalog.appURL.deletingPathExtension().lastPathComponent).font(.headline)
                }
                if mode == "direct" {
                    DisclosureGroup(isExpanded: $showsBuildDetails) {
                        LabeledContent("Path", value: catalog.appURL.path)
                        LabeledContent("Bundle identifier", value: catalog.bundleIdentifier)
                        if let product = catalog.productIdentity {
                            LabeledContent("Build", value: String(product.sha256.prefix(10)))
                        }
                    } label: {
                        Text("Build details").contentShape(Rectangle()).onTapGesture { showsBuildDetails.toggle() }
                    }
                }
            }
        }
    }

    /// Groups the Direct Action inputs, signing options, and result in a native form.
    private var configurationForm: some View {
        Form {
            Section {
                DisclosureGroup(isExpanded: $showsSupportedTypes) {
                    Text("Intents generates a native UI test. Compiled metadata discovery is best effort. Native macOS validation covers String, Bool, Int, Double and enum inputs, String and Double results, and execution-only smoke checks. A smoke check does not compare the returned value.")
                        .foregroundStyle(.secondary)
                } label: {
                    Text("Supported inputs and results").contentShape(Rectangle()).onTapGesture { showsSupportedTypes.toggle() }
                }
            }
            if let catalog = model.catalog, !catalog.actions.isEmpty {
                Section("Action and inputs") {
                    Picker("Action", selection: $model.selectedActionID) {
                        ForEach(catalog.actions) { action in
                            Text("\(action.title) — \(action.id)").tag(action.id)
                        }
                    }
                    if let action = model.selectedAction {
                        ForEach(action.parameters) { parameter in
                            LabeledContent(parameter.id, value: "\(parameter.type)\(parameter.required ? " · required" : "")")
                        }
                    }
                    Text("Inputs JSON · use the parameter identifiers above")
                    TextEditor(text: $model.inputsJSON).font(.body.monospaced()).frame(minHeight: 100)
                        .accessibilityLabel("Inputs JSON")
                    Toggle("Compare returned value", isOn: $model.checksExpectedValue)
                        .accessibilityLabel("Compare returned value")
                    if model.checksExpectedValue {
                        Text("Expected value JSON")
                        TextEditor(text: $model.expectedValueJSON).font(.body.monospaced()).frame(minHeight: 70)
                            .accessibilityLabel("Expected value JSON")
                    } else {
                        Text("Execution-only smoke check. No expected result is asserted.").foregroundStyle(.secondary)
                    }
                }
                .disabled(model.isRunning || model.siri.isBusy)
                Section("Xcode and signing") {
                    TextField("Developer directory", text: $model.developerDirectory)
                        .accessibilityLabel("Developer directory")
                    TextField("Signing identity", text: $model.signingIdentity, prompt: Text("Apple Development: …"))
                        .accessibilityLabel("Signing identity")
                    TextField("Team identifier", text: $model.teamIdentifier)
                        .accessibilityLabel("Team identifier")
                    Text("Use a local Xcode installation and a development identity permitted to sign the generated test host. These fields do not verify the app’s entitlements or signing compatibility.").foregroundStyle(.secondary)
                }
                .disabled(model.isRunning || model.siri.isBusy)
                Section {
                    HStack {
                        Button("Run native test") { model.start() }.disabled(model.isRunning || model.siri.isBusy)
                        Button("Cancel") { model.cancel() }.disabled(!model.isRunning)
                        if model.isRunning { ProgressView().controlSize(.small) }
                    }
                }
            }
            if let diagnostic = model.diagnostic {
                Section("Diagnostic") { Text(diagnostic).textSelection(.enabled) }
            }
            if let result = model.result {
                Section(result.succeeded ? "Test passed" : "Test did not pass") {
                    Text(result.summary).textSelection(.enabled)
                    if let identity = result.productIdentity {
                        LabeledContent("Tested build", value: String(identity.sha256.prefix(16)))
                    }
                    Button("Show log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.logURL]) }
                    Text(result.logURL.path).font(.caption).textSelection(.enabled)
                    if let url = result.resultBundleURL {
                        Button("Open result bundle") { NSWorkspace.shared.open(url) }
                        Text(url.path).font(.caption).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
        .scrollContentBackground(.hidden)
    }
}
