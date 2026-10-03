import SwiftUI

/// The ordinary v3 editor reads only the declaration from the checked test
/// product and the negotiated interface from a connected app runner.
struct ScenarioGuidedActionFeatureView: View {
    @Bindable var coordinator: ScenarioCoordinator
    let runnerStore: DeveloperRunnerStore

    private var connectedRunners: [DeveloperRunnerSnapshot] {
        runnerStore.runners.filter { $0.state == .connected &&
            $0.identity.appBundleIdentifier == coordinator.draft.target.bundleIdentifier }
    }

    private var availableFeatures: [DeveloperFeatureDescriptor] {
        let selectedID = ScenarioRunnerSelection.chosenID(
            candidateIDs: connectedRunners.map(\.id), selectedID: runnerStore.selectedRunnerID
        )
        return connectedRunners
            .filter { $0.id == selectedID }
            .flatMap(\.features)
            .filter { $0.subjectInputSchema != nil &&
                $0.capabilityNames.contains(DeveloperSubjectInputSchema.capabilityName) }
            .sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let catalog = coordinator.declarationCatalog {
                Picker("App action", selection: Binding(
                    get: { coordinator.draft.directControl.intentIdentifier },
                    set: { coordinator.selectDeclaredAction($0) }
                )) {
                    Text("Choose an action").tag("")
                    ForEach(catalog.actions) { action in Text(action.id).tag(action.id) }
                }
                .accessibilityIdentifier("Declared app action")
            } else {
                Label("Rebuild and check support to load the app's actions.", systemImage: "wrench.and.screwdriver")
                    .foregroundStyle(.orange)
            }

            if connectedRunners.count > 1 {
                Picker("Connected app build", selection: Binding(
                    get: { runnerStore.selectedRunnerID },
                    set: { runnerStore.selectedRunnerID = $0 }
                )) {
                    Text("Choose the app build").tag(UUID?.none)
                    ForEach(connectedRunners) { runner in
                        Text("\(runner.identity.displayName) · \(runner.identity.appVersion)")
                            .tag(UUID?.some(runner.id))
                    }
                }
                .accessibilityIdentifier("Connected app build")
            }
            Picker("App feature", selection: Binding(
                get: { coordinator.draft.featureBinding?.featureID ?? "" },
                set: { selectFeature($0) }
            )) {
                Text("Choose a connected feature").tag("")
                ForEach(availableFeatures) { feature in
                    Text(feature.displayName).tag(feature.id)
                }
            }
            .accessibilityIdentifier("Declared app feature")
            if availableFeatures.isEmpty {
                Text(connectedRunners.count > 1
                     ? "Choose the connected app build to see its declared features."
                     : "Connect the app's developer runner, declare subject inputs, then rebuild and check support.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let feature = availableFeatures.first(where: { $0.id == coordinator.draft.featureBinding?.featureID }),
               let schema = feature.subjectInputSchema {
                ForEach(schema.fields, id: \.name) { field in
                    featureInput(field)
                }
            }
        }
        .padding(12)
        .workspaceInset(radius: 10)
    }

    private func selectFeature(_ id: String) {
        guard let feature = availableFeatures.first(where: { $0.id == id }),
              let schema = feature.subjectInputSchema,
              let digest = try? ScenarioSubjectFeatureAdapter.interfaceDigest(feature) else {
            coordinator.draft.featureBinding = nil
            coordinator.invalidatePreflight()
            return
        }
        coordinator.draft.featureBinding = .init(
            featureID: feature.id, interfaceDigest: digest,
            inputMapping: schema.fields.map {
                .init(featureInputName: $0.name, value: defaultValue(for: $0.valueType))
            }, outputProjections: []
        )
        if let selectedID = ScenarioRunnerSelection.chosenID(
            candidateIDs: connectedRunners.map(\.id), selectedID: runnerStore.selectedRunnerID
        ) {
            runnerStore.selectedRunnerID = selectedID
        }
        coordinator.draft.coverage.appFeature = .required
        coordinator.invalidatePreflight()
    }

    @ViewBuilder private func featureInput(_ field: DeveloperSubjectInputField) -> some View {
        let index = coordinator.draft.featureBinding?.inputMapping.firstIndex {
            $0.featureInputName == field.name
        }
        if let index {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(field.name).frame(width: 150, alignment: .leading)
                switch field.valueType {
                case .string:
                    TextField(field.name, text: mapped(index, default: "", get: {
                        if case .string(let value) = $0 { value } else { nil }
                    }, wrap: ScenarioValue.string))
                case .boolean:
                    Toggle(field.name, isOn: mapped(index, default: false, get: {
                        if case .boolean(let value) = $0 { value } else { nil }
                    }, wrap: ScenarioValue.boolean)).labelsHidden()
                case .integer:
                    TextField(field.name, value: mapped(index, default: Int64(0), get: {
                        if case .integer(let value) = $0 { value } else { nil }
                    }, wrap: ScenarioValue.integer), format: .number)
                case .number:
                    TextField(field.name, value: mapped(index, default: 0.0, get: {
                        if case .number(let value) = $0 { value } else { nil }
                    }, wrap: ScenarioValue.number), format: .number)
                case .array, .object:
                    Text("Nested input needs app-specific mapping support in this editor.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .accessibilityIdentifier("Feature input \(field.name)")
        }
    }

    private func mapped<Value>(
        _ index: Int, default fallback: Value,
        get: @escaping (ScenarioValue) -> Value?, wrap: @escaping (Value) -> ScenarioValue
    ) -> Binding<Value> {
        Binding(get: {
            guard let binding = coordinator.draft.featureBinding,
                  binding.inputMapping.indices.contains(index) else { return fallback }
            return get(binding.inputMapping[index].value) ?? fallback
        }, set: { value in
            guard coordinator.draft.featureBinding?.inputMapping.indices.contains(index) == true else { return }
            coordinator.draft.featureBinding?.inputMapping[index].value = wrap(value)
            coordinator.invalidatePreflight()
        })
    }

    private func defaultValue(for type: DeveloperSubjectValueType) -> ScenarioValue {
        switch type {
        case .string: .string("")
        case .boolean: .boolean(false)
        case .integer: .integer(0)
        case .number: .number(0)
        case .array: .array([])
        case .object: .null
        }
    }
}

/// Each add or edit delegates to the atomic authoring operation; projection,
/// observer, assertion, and proof claim cannot drift apart through this UI.
struct ScenarioGuidedExpectationView: View {
    @Bindable var coordinator: ScenarioCoordinator
    @State private var selection = ""
    @State private var proposedValue: ScenarioValue? = .string("")
    @State private var checkIntent = true
    @State private var checkSiri = true
    @State private var semanticFeature = false
    @State private var featureRubric = ""

    private var choices: [(id: String, title: String, type: ScenarioValueType, state: Bool)] {
        guard let catalog = coordinator.declarationCatalog else { return [] }
        let feature: [(id: String, title: String, type: ScenarioValueType, state: Bool)] =
            coordinator.draft.featureBinding == nil ? []
            : [("feature.response", "App Feature · captured response", .primitive(.string), false)]
        return feature + catalog.resultProjections.map { ($0.id, "Returned · \($0.id)", $0.type, false) }
            + catalog.observers.filter { $0.source.checksApplicationState }
                .map { ($0.id, "App state · \($0.id)", $0.type, true) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if coordinator.declarationCatalog == nil {
                Text("Rebuild and check support to choose an observable result.")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Picker("Observed result", selection: $selection) {
                    Text("Choose a result or app state").tag("")
                    ForEach(choices, id: \.id) { choice in
                        Text(choice.title).tag(choice.id)
                    }
                }
                .accessibilityIdentifier("Declared observed result")
                .onChange(of: selection) { _, id in
                    if let choice = choices.first(where: { $0.id == id }) {
                        proposedValue = ScenarioDeclaredExpectedValues.initial(for: choice.type)
                    }
                }
                if let choice = choices.first(where: { $0.id == selection }) {
                    ScenarioDeclaredExpectedValueEditor(type: choice.type, value: $proposedValue)
                        .id(choice.id)
                    if let proposedValue {
                        ForEach(ScenarioValidator.validate(value: proposedValue, as: choice.type), id: \.self) {
                            Text($0).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    if selection == "feature.response" {
                        Toggle("Assess meaning with an independent judge", isOn: $semanticFeature)
                        if semanticFeature {
                            TextField("What makes this response correct?", text: $featureRubric, axis: .vertical)
                                .lineLimit(2...4)
                            Text("The reference and rubric stay in Intents. They are not sent to your app feature.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        HStack {
                            Toggle("Intent", isOn: $checkIntent)
                            Toggle("Siri", isOn: $checkSiri)
                        }
                    }
                    Button("Add expected outcome", systemImage: "plus.circle") { addCheck() }
                        .disabled(proposedValue == nil
                                  || proposedValue.map { !ScenarioValidator.validate(value: $0, as: choice.type).isEmpty } == true
                                  || (selection != "feature.response" && !checkIntent && !checkSiri)
                                  || (selection == "feature.response" && semanticFeature
                                      && featureRubric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        .accessibilityIdentifier("Add expected outcome")
                }
            }
            ForEach(coordinator.draft.assertions) { assertion in
                HStack {
                    Text(assertion.observationKey).font(.callout.weight(.medium))
                    let expected = Binding<ScenarioValue?>(
                        get: { coordinator.draft.assertions.first { $0.id == assertion.id }?.expectedValue },
                        set: { value in
                            if let value { coordinator.updateCheck(assertion.id, expected: value) }
                        }
                    )
                    if let choice = choices.first(where: { $0.id == assertion.observationKey }) {
                        ScenarioDeclaredExpectedValueEditor(type: choice.type, value: expected)
                    } else {
                        ScenarioExpectedValueEditor(value: expected)
                    }
                    Button("Remove check", systemImage: "trash", role: .destructive) {
                        coordinator.removeCheck(assertion.id)
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        .padding(12)
        .workspaceInset(radius: 10)
    }

    private func addCheck() {
        guard let choice = choices.first(where: { $0.id == selection }),
              let expected = proposedValue else { return }
        if choice.id == "feature.response" {
            do {
                coordinator.draft = try ScenarioExpectationAuthoring.addingFeatureResponseCheck(
                    expected: expected, semantic: semanticFeature, rubric: featureRubric,
                    to: coordinator.draft
                )
                coordinator.invalidatePreflight()
            } catch { coordinator.notice = error.localizedDescription }
            return
        }
        var lanes: Set<ScenarioLane> = []
        if checkIntent { lanes.insert(.intentIntegration) }
        if checkSiri { lanes.insert(.siri) }
        if choice.state {
            coordinator.addStateCheck(observerID: choice.id, kind: .stateTransition,
                                      expected: expected, lanes: lanes)
        } else {
            coordinator.addReturnedCheck(projectionID: choice.id, expected: expected, lanes: lanes)
        }
    }

}

/// Edits the declaration's value type, including each item in a declared array.
private struct ScenarioDeclaredExpectedValueEditor: View {
    let type: ScenarioValueType
    @Binding var value: ScenarioValue?

    private var arrayItems: [ScenarioValue] {
        guard case .array(let items)? = value else { return [] }
        return items
    }

    @ViewBuilder var body: some View {
        switch type {
        case .array(let element):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(arrayItems.indices, id: \.self) { index in
                    HStack {
                        ScenarioDeclaredScalarEditor(type: element, value: Binding(
                            get: { arrayItems.indices.contains(index) ? arrayItems[index] : nil },
                            set: { updateItem(index, to: $0) }
                        ))
                        Button("Remove item", systemImage: "minus.circle", role: .destructive) {
                            var items = arrayItems
                            items.remove(at: index)
                            value = .array(items)
                        }
                        .labelStyle(.iconOnly)
                    }
                }
                Button("Add expected item", systemImage: "plus.circle") {
                    guard let item = ScenarioDeclaredExpectedValues.initial(for: element) else {
                        return
                    }
                    value = .array(arrayItems + [item])
                }
                .disabled(ScenarioDeclaredExpectedValues.initial(for: element) == nil)
            }
        default:
            ScenarioDeclaredScalarEditor(type: type, value: $value)
        }
    }

    private func updateItem(_ index: Int, to item: ScenarioValue?) {
        guard let item, arrayItems.indices.contains(index) else { return }
        var items = arrayItems
        items[index] = item
        value = .array(items)
    }
}

private struct ScenarioDeclaredScalarEditor: View {
    let type: ScenarioValueType
    @Binding var value: ScenarioValue?

    @ViewBuilder var body: some View {
        switch type {
        case .primitive(.string):
            TextField("Expected text", text: Binding(
                get: { if case .string(let item)? = value { item } else { "" } },
                set: { value = .string($0) }
            ))
        case .primitive(.boolean):
            Toggle("Expected", isOn: Binding(
                get: { if case .boolean(let item)? = value { item } else { false } },
                set: { value = .boolean($0) }
            ))
        case .primitive(.integer):
            TextField("Expected integer", value: Binding(
                get: { if case .integer(let item)? = value { item } else { 0 } },
                set: { value = .integer($0) }
            ), format: .number)
        case .primitive(.number):
            TextField("Expected number", value: Binding(
                get: { if case .number(let item)? = value { item } else { 0 } },
                set: { value = .number($0) }
            ), format: .number)
        case .primitive(.date):
            DatePicker("Expected date", selection: Binding(
                get: { if case .date(let item)? = value { item.resolvedInstant } else { Date() } },
                set: { instant in
                    value = .date(.init(source: ISO8601DateFormatter().string(from: instant),
                                        timeZoneIdentifier: TimeZone.current.identifier,
                                        resolvedInstant: instant))
                }
            ))
        case .enumeration(let typeIdentifier, let cases):
            Picker("Expected case", selection: Binding(
                get: { if case .enumeration(let item)? = value { item.caseIdentifier } else { cases.first ?? "" } },
                set: { value = .enumeration(.init(typeIdentifier: typeIdentifier, caseIdentifier: $0)) }
            )) {
                ForEach(cases, id: \.self) { Text($0).tag($0) }
            }
        case .entity(let typeIdentifier):
            VStack(alignment: .leading) {
                TextField("Stable entity identifier", text: Binding(
                    get: { if case .entity(let item)? = value { item.identifier } else { "" } },
                    set: { value = .entity(.init(typeIdentifier: typeIdentifier, identifier: $0)) }
                ))
                Text("Enter an app-owned identifier. Its resolution is checked during the run.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .array:
            Text("Nested arrays are not supported by this declaration.")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}
