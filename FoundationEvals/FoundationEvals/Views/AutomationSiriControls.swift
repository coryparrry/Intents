import SwiftUI
import IntentsAutomationCore

struct AutomationSiriControls: View {
    @Bindable var model: AppAutomationStore
    let review: () -> Void
    var body: some View {
        GroupBox("Siri recognised-text submission") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Exact request to submit to Siri", text: $model.siriRequest, axis: .vertical)
                    .accessibilityLabel("Exact request to submit to Siri")
                    .onChange(of: model.siriRequest) { model.workflowSelectionChanged() }
                Toggle("Check an existing record's state", isOn: $model.siriOracle.enabled)
                if model.siriOracle.enabled {
                    Picker("Record type", selection: $model.siriOracle.entityType) {
                        Text("Choose a readable record type").tag("")
                        ForEach(model.catalog?.entities ?? []) { Text($0.title).tag($0.typeID) }
                    }.accessibilityLabel("Siri record type")
                    Picker("Name to identify the record", selection: $model.siriOracle.nameProperty) {
                        Text("Choose its name property").tag("")
                        ForEach((model.siriEntity?.properties ?? [:]).filter { $0.value == "text" }.keys.sorted(), id: \.self) { property in
                            Text(model.siriEntity?.propertyTitles[property] ?? property).tag(property)
                        }
                    }.accessibilityLabel("Siri record name property")
                    TextField("Exact existing record name", text: $model.siriOracle.recordName)
                        .accessibilityLabel("Exact existing Siri record name")
                    Picker("State to check", selection: $model.siriOracle.stateProperty) {
                        Text("Choose its state property").tag("")
                        ForEach((model.siriEntity?.properties ?? [:]).filter { $0.value == "bool" }.keys.sorted(), id: \.self) { property in
                            Text(model.siriEntity?.propertyTitles[property] ?? property).tag(property)
                        }
                    }.accessibilityLabel("Siri record state property")
                    Picker("State before Siri", selection: $model.siriOracle.initialState) {
                        Text("Choose the initial state").tag(""); Text("False").tag("false"); Text("True").tag("true")
                    }.accessibilityLabel("State before Siri")
                    Picker("Expected state after Siri", selection: $model.siriOracle.expectedState) {
                        Text("Choose a different expected state").tag(""); Text("False").tag("false"); Text("True").tag("true")
                    }.accessibilityLabel("Expected state after Siri")
                    Text("Use an existing disposable test record. Intents requires one exact name match, queries its initial state, then checks that same record after Siri. It does not create or reset records.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Picker("Effects of this request", selection: $model.effectChoice) {
                    Text("Choose the request's effects").tag("")
                    Text("Observation and navigation").tag("navigation")
                    Text("Changes to test fixtures").tag("fixture")
                    Text("External changes").tag("external")
                }.accessibilityLabel("Effects of this request")
                Toggle("I confirm this request stays within these effects", isOn: $model.effectsConfirmed)
                Toggle("Disposable test environment", isOn: $model.disposable)
                Toggle("Allow installing the prepared app on this device", isOn: $model.installApproved)
                Text(model.siriOracle.enabled ? "This state check requires permission to change test fixtures. A returned Siri call alone cannot pass: the approved record must show the expected change through an independent query. It does not prove speech recognition or the bytes installed on the device." : "The app can change data after Siri receives the request. Submission is unassessed: it does not prove speech recognition, app routing or the requested outcome.")
                    .font(.callout).foregroundStyle(.secondary)
                if model.prepared == nil || !model.siriCapabilities.supports(["siri.recognizedText.api"]) {
                    Text("Prepare a physical-device host to check that the submission API compiles. Connect and unlock that exact device before running.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button(model.siriOracle.enabled ? "Review Siri state check…" : "Review Siri submission…", action: review)
                    .disabled(!model.canRun || model.pendingCommandStatus?.kind != nil)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10).disabled(model.busy)
                .onChange(of: model.siriOracle) { model.workflowSelectionChanged() }
        }
    }
}
