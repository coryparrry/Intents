#if os(macOS)
import SwiftUI
import IntentsAutomationCore

struct AutomationPairedFeatureControls: View {
    @Bindable var model: AppAutomationStore
    @State private var review: AutomationNativePairedReview?
    var body: some View {
        if !model.availablePairedFeatures.isEmpty {
            GroupBox("Connected app feature") {
                VStack(alignment: .leading, spacing: 10) {
                    if model.availablePairedFeatures.count == 1 {
                        Text(model.availablePairedFeatures[0].title).font(.headline)
                    } else {
                        Picker("Feature", selection: $model.pairedFeatureID) {
                            Text("Choose feature").tag("")
                            ForEach(model.availablePairedFeatures) { Text($0.title).tag($0.id) }
                        }.onChange(of: model.pairedFeatureID) { model.pairedEffectsConfirmed = false }
                    }
                    TextField("Request for the app", text: $model.pairedPrompt, axis: .vertical)
                    DisclosureGroup("Instructions and expected response") {
                        TextField("Instructions for the feature (optional)", text: $model.pairedInstructions, axis: .vertical)
                        TextField("Exact expected response (optional)", text: $model.pairedExpectedResponse, axis: .vertical)
                        Text("The expected response stays in Intents. Without it, the returned response is recorded without a correctness verdict.").font(.callout).foregroundStyle(.secondary)
                    }
                    Picker("Permitted effects", selection: $model.effectChoice) {
                        Text("Choose the feature's effects").tag("")
                        Text("Read-only").tag("navigation")
                        Text("Changes to disposable test records").tag("fixture")
                        Text("Changes to this app's data").tag("external")
                    }.onChange(of: model.effectChoice) { model.pairedEffectsConfirmed = false }
                    if model.effectChoice == "fixture" { Toggle("This is a disposable test environment", isOn: $model.disposable) }
                    Toggle("I confirm this request stays within the selected effects", isOn: $model.pairedEffectsConfirmed)
                    Button("Run app feature…") {
                        do { review = try model.reviewPairedFeature() }
                        catch { model.message = model.errorText(error) }
                    }.disabled(!model.canRunPairedFeature).accessibilityIdentifier("automation.runPairedFeature")
                    Text("Uses the connected app's registered feature. Its reported app and feature versions are retained; remote build bytes and model internals are not verified.")
                        .font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).disabled(model.busy)
            }
            .sheet(item: $review) { reviewed in
                VStack(alignment: .leading, spacing: 16) {
                    Text("Run \(reviewed.title)?").font(.title2)
                    Text(reviewed.plan.execution.pairedProgram?.prompt ?? "").textSelection(.enabled)
                    Text("App version: \(reviewed.plan.execution.pairedProgram?.appVersion ?? "") · Feature version: \(reviewed.plan.execution.pairedProgram?.featureVersion ?? "")")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("One request will be sent through the existing trusted connection. A timeout or disconnect leaves the outcome unresolved and blocks automatic repetition.")
                    HStack {
                        Spacer()
                        Button("Cancel", role: .cancel) { review = nil }
                        Button("Run approved feature") { review = nil; model.runPairedFeature(reviewed) }.keyboardShortcut(.defaultAction)
                    }
                }.padding(24).frame(width: 540)
            }
        }
    }
}
#endif
