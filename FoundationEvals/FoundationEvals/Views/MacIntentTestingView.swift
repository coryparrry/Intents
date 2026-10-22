import MacIntentTesting
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MacIntentTestingView: View {
    @Bindable var model: MacIntentTestingStore
    @State private var choosingApp = false

    var body: some View {
        ScrollView {
            Form {
                Section {
                    Text("App Intent Testing").font(.largeTitle.bold())
                    Text("Run an action from a built macOS app using a generated native UI test. Install and launch the app normally once so LaunchServices registers it, then quit it before selecting and testing the build.")
                    Text("Compiled metadata discovery is best effort. Native macOS validation covers String, Bool, Int, Double and enum inputs, String and Double results, and execution-only smoke checks. A smoke check does not compare the returned value.")
                        .foregroundStyle(.secondary)
                    Button("Choose built macOS app…") { choosingApp = true }
                        .disabled(model.isRunning)
                    if let catalog = model.catalog {
                        LabeledContent("Application", value: catalog.appURL.path)
                        LabeledContent("Bundle identifier", value: catalog.bundleIdentifier)
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
                            TextEditor(text: $model.expectedValueJSON).font(.body.monospaced()).frame(minHeight: 70)
                                .accessibilityLabel("Expected value JSON")
                        } else {
                            Text("Execution-only smoke check. No expected result is asserted.").foregroundStyle(.secondary)
                        }
                    }
                    .disabled(model.isRunning)
                    Section("Xcode and signing") {
                        TextField("Developer directory", text: $model.developerDirectory)
                            .accessibilityLabel("Developer directory")
                        TextField("Signing identity", text: $model.signingIdentity, prompt: Text("Apple Development: …"))
                            .accessibilityLabel("Signing identity")
                        TextField("Team identifier", text: $model.teamIdentifier)
                            .accessibilityLabel("Team identifier")
                        Text("Use a local Xcode installation and a development identity permitted to sign the generated test host. These fields do not verify the app’s entitlements or signing compatibility.").foregroundStyle(.secondary)
                    }
                    .disabled(model.isRunning)
                    Section {
                        HStack {
                            Button("Run native test") { model.start() }.disabled(model.isRunning)
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
            .padding()
        }
        .fileImporter(isPresented: $choosingApp, allowedContentTypes: [.applicationBundle]) { result in
            do { model.load(appURL: try result.get()) }
            catch { model.reportSelectionError(error) }
        }
    }
}
