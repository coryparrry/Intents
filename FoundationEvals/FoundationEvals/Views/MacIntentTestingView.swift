import MacIntentTesting
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MacIntentTestingView: View {
    @Bindable var model: MacIntentTestingStore
    @State private var choosingApp = false
    @State private var showsBuildDetails = false
    @State private var showsSupportedTypes = false
    @State private var showsAdvancedOptions = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                WorkspacePageHeader("App Intents", subtitle: "Test an action from a built macOS app.")
                configurationForm
            }
            .workspacePage()
        }
        .accessibilityIdentifier("App Intent steps")
        .fileImporter(isPresented: $choosingApp, allowedContentTypes: [.applicationBundle]) { result in
            do { model.load(appURL: try result.get()) }
            catch { model.reportSelectionError(error) }
        }
    }

    /// Presents App Intents testing as three focused steps with advanced signing details kept optional.
    private var configurationForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepCard(number: 1, title: "Choose app") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Install and launch the app normally once to register it, then quit it before choosing its build.")
                    Button("Choose built macOS app…") { choosingApp = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isRunning)
                    if model.isLoading {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Inspecting built app…")
                            Button("Cancel") { model.cancel() }
                        }
                    }
                    if let catalog = model.catalog {
                        LabeledContent("Application", value: catalog.appURL.deletingPathExtension().lastPathComponent)
                        DisclosureGroup(isExpanded: $showsBuildDetails) {
                            LabeledContent("Path", value: catalog.appURL.path)
                            LabeledContent("Bundle identifier", value: catalog.bundleIdentifier)
                        } label: {
                            Text("Build details").contentShape(Rectangle()).onTapGesture { showsBuildDetails.toggle() }
                        }
                    }
                }
                DisclosureGroup(isExpanded: $showsSupportedTypes) {
                    Text("Intents generates a native UI test. Compiled metadata discovery is best effort. Native macOS validation covers String, Bool, Int, Double and enum inputs, String and Double results, and execution-only smoke checks. A smoke check does not compare the returned value.")
                        .foregroundStyle(.secondary)
                } label: {
                    Text("Supported inputs and results").contentShape(Rectangle()).onTapGesture { showsSupportedTypes.toggle() }
                }
            }

            stepCard(number: 2, title: "Action and inputs") {
                if let catalog = model.catalog, !catalog.actions.isEmpty {
                    Group {
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
                            .toggleStyle(.switch)
                            .accessibilityLabel("Compare returned value")
                        if model.checksExpectedValue {
                            Text("Expected value JSON")
                            TextEditor(text: $model.expectedValueJSON).font(.body.monospaced()).frame(minHeight: 70)
                                .accessibilityLabel("Expected value JSON")
                        } else {
                            Text("Execution-only smoke check. No expected result is asserted.").foregroundStyle(.secondary)
                        }
                    }
                    .disabled(model.isRunning)
                } else if model.catalog != nil {
                    Text("No App Intents were found in this app.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Choose an app to inspect its actions and inputs.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            stepCard(number: 3, title: "Run and result") {
                if let catalog = model.catalog, !catalog.actions.isEmpty {
                    HStack {
                        Button("Run native test") { model.start() }.disabled(model.isRunning)
                        Button("Cancel") { model.cancel() }.disabled(!model.isRunning)
                        if model.isRunning { ProgressView().controlSize(.small) }
                    }
                    if let result = model.result {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(result.succeeded ? "Test passed" : "Test did not pass").font(.headline)
                            Text(result.summary).textSelection(.enabled)
                            if let identity = result.productIdentity {
                                LabeledContent("Tested build", value: String(identity.sha256.prefix(16)))
                            }
                        }
                    }
                } else if model.catalog == nil {
                    Text("Choose an app to prepare a native test run.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Choose an app with an App Intent to run a native test.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup(isExpanded: $showsAdvancedOptions) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Developer directory", text: $model.developerDirectory)
                            .accessibilityLabel("Developer directory")
                        TextField("Signing identity", text: $model.signingIdentity, prompt: Text("Apple Development: …"))
                            .accessibilityLabel("Signing identity")
                        TextField("Team identifier", text: $model.teamIdentifier)
                            .accessibilityLabel("Team identifier")
                        Text("Use a local Xcode installation and a development identity permitted to sign the generated test host. These fields do not verify the app’s entitlements or signing compatibility.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if let diagnostic = model.diagnostic {
                            Text(diagnostic).textSelection(.enabled)
                        }
                        if let result = model.result {
                            Button("Show log in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([result.logURL])
                            }
                            Text(result.logURL.path).font(.caption).textSelection(.enabled)
                            if let url = result.resultBundleURL {
                                Button("Open result bundle") { NSWorkspace.shared.open(url) }
                                Text(url.path).font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                }
                label: {
                    Text("Advanced: build and signing")
                        .contentShape(Rectangle())
                        .onTapGesture { showsAdvancedOptions.toggle() }
                }
                .disabled(model.isRunning)
            }
        }
    }

    /// Wraps one step in a consistent surface with a numbered accessible heading.
    private func stepCard<Content: View>(
        number: Int,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text(number.formatted())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Color.accentColor, in: Circle())
                Text(title)
                    .font(.headline)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(number)  \(title)")
            .accessibilityIdentifier("App Intent step \(number)")
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workspaceSurface()
    }
}
