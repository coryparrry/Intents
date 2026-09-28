import SwiftUI

struct ScenarioReusableChecksView: View {
    @Bindable var coordinator: ScenarioCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Purpose", selection: Binding(
                get: { coordinator.draft.purpose ?? .exploratory },
                set: { coordinator.draft.purpose = $0; coordinator.draft.definitionDigest = "" }
            )) {
                Text("Explore an intent").tag(ScenarioPurpose.exploratory)
                Text("Release requirement").tag(ScenarioPurpose.releaseRequirement)
            }
            Picker("Check mode", selection: Binding(
                get: { coordinator.draft.checkMode ?? .basic },
                set: { mode in
                    coordinator.draft.checkMode = mode
                    var claims = coordinator.draft.requiredClaims ?? [.executionCompleted]
                    if mode == .basic {
                        claims.removeAll { $0 == .applicationStateChecked }
                    } else if !claims.contains(.applicationStateChecked) {
                        claims.append(.applicationStateChecked)
                    }
                    coordinator.draft.requiredClaims = claims
                    coordinator.draft.definitionDigest = ""
                }
            )) {
                Text("Basic: execution and optional return values").tag(ScenarioCheckMode.basic)
                Text("Behaviour: observed app state").tag(ScenarioCheckMode.behaviour)
            }
            IntentLabHelp(coordinator.draft.checkMode == .basic
                ? "Execution passed means only that the intent ran. Application state was not checked. Add a returned-value assertion to check an output."
                : "Behaviour checks need a real post-action observation and a required assertion. A returned value alone does not prove a saved change.")
            if coordinator.draft.checkMode == .basic {
                Toggle("Require returned value check", isOn: claimBinding(.returnedValueChecked))
                IntentLabHelp("Choose a returned result observation and add a required Returned field assertion when this is on.")
            }
            DisclosureGroup("Where to read results") {
                observationPlanControls.padding(.top, 8)
            }
        }
        .padding(12)
        .workspaceInset(radius: 10)
    }

    private var observationPlanControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Observations").font(.callout.weight(.semibold))
                Spacer()
                Button("Add observation", systemImage: "plus") {
                    var plan = coordinator.draft.observationPlan ?? []
                    plan.append(.init(id: "observation-\(plan.count + 1)", source: .uiElement, operationID: "", selector: ""))
                    coordinator.draft.observationPlan = plan
                    coordinator.draft.definitionDigest = ""
                }
                .buttonStyle(.borderless)
            }
            if (coordinator.draft.observationPlan ?? []).isEmpty {
                Text("No observations declared. An exploratory Basic check can run without them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array((coordinator.draft.observationPlan ?? []).indices), id: \.self) { index in
                let observation = observationBinding(index)
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        TextField("Observation ID", text: observation.id)
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            coordinator.draft.observationPlan?.remove(at: index)
                            coordinator.draft.definitionDigest = ""
                        }
                        .labelStyle(.iconOnly)
                    }
                    Picker("Source", selection: observation.source) {
                        Text("Intent result").tag(ScenarioPlannedObservationSource.intentResult)
                        Text("Entity query").tag(ScenarioPlannedObservationSource.entityQuery)
                        Text("Value query").tag(ScenarioPlannedObservationSource.valueQuery)
                        Text("UI element").tag(ScenarioPlannedObservationSource.uiElement)
                        Text("Test-only intent").tag(ScenarioPlannedObservationSource.testOnlyIntent)
                    }
                    if observation.wrappedValue.source != .intentResult {
                        TextField("Compiled operation ID", text: optionalText(observation.operationID))
                    }
                    TextField("Stable selector or property", text: optionalText(observation.selector))
                }
                .padding(10)
                .workspaceInset(radius: 8)
            }
            IntentLabHelp("Select the source that actually reads the outcome. A query or test hook must be implemented by the app's integration; naming one here does not verify it.")
        }
    }

    private func claimBinding(_ claim: ScenarioProofClaim) -> Binding<Bool> {
        Binding(
            get: { coordinator.draft.requiredClaims?.contains(claim) == true },
            set: { enabled in
                var claims = coordinator.draft.requiredClaims ?? [.executionCompleted]
                claims.removeAll { $0 == claim }
                if enabled { claims.append(claim) }
                coordinator.draft.requiredClaims = claims
                coordinator.draft.definitionDigest = ""
            }
        )
    }

    private func observationBinding(_ index: Int) -> Binding<ScenarioPlannedObservation> {
        Binding(
            get: { coordinator.draft.observationPlan![index] },
            set: { value in
                coordinator.draft.observationPlan?[index] = value
                coordinator.draft.definitionDigest = ""
            }
        )
    }

    private func optionalText(_ value: Binding<String?>) -> Binding<String> {
        Binding(
            get: { value.wrappedValue ?? "" },
            set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}

/// Edits only declared result projections. Paths are a bounded sequence of
/// components and never executable expressions or reflected object dumps.
struct ScenarioResultProjectionEditor: View {
    @Bindable var coordinator: ScenarioCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Returned values").font(.callout.weight(.semibold))
                Spacer()
                Button("Add returned value", systemImage: "plus") {
                    let count = coordinator.draft.directControl.outputFields.count
                    coordinator.draft.directControl.outputFields.append(.init(
                        name: "result-\(count + 1)",
                        type: .primitive(.string),
                        path: [.init(kind: .property, name: "value")]
                    ))
                    coordinator.draft.definitionDigest = ""
                }
                .buttonStyle(.borderless)
            }
            ForEach(Array(coordinator.draft.directControl.outputFields.indices), id: \.self) { index in
                let field = fieldBinding(index)
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        TextField("Observation ID", text: field.name)
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            coordinator.draft.directControl.outputFields.remove(at: index)
                            coordinator.draft.definitionDigest = ""
                        }
                        .labelStyle(.iconOnly)
                    }
                    TextField("Display name", text: optionalText(field.displayName))
                    Picker("Value type", selection: Binding(
                        get: { ProjectionValueChoice(field.wrappedValue.type) },
                        set: { field.wrappedValue.type = $0.valueType }
                    )) {
                        ForEach(ProjectionValueChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    HStack {
                        Text("Extraction path").font(.caption.weight(.medium))
                        Spacer()
                        Button("Add property", systemImage: "plus") { append(.init(kind: .property, name: "property"), to: index) }
                        Button("Add index", systemImage: "plus") { append(.init(kind: .index, index: 0), to: index) }
                        Button("Add count", systemImage: "plus") { append(.init(kind: .count), to: index) }
                    }
                    .buttonStyle(.borderless)
                    ForEach(Array((field.wrappedValue.path ?? []).indices), id: \.self) { componentIndex in
                        let component = pathBinding(field: index, component: componentIndex)
                        HStack {
                            Text(componentIndex == 0 ? "Root" : "Then")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(component.wrappedValue.kind.rawValue)
                                .font(.caption).frame(width: 55, alignment: .leading)
                            switch component.wrappedValue.kind {
                            case .property:
                                TextField("Property name", text: optionalText(component.name))
                            case .index:
                                TextField("Index", value: optionalInt(component.index), format: .number)
                                    .frame(width: 75)
                            case .count:
                                Text("Collection count").font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Remove path step", systemImage: "minus.circle", role: .destructive) {
                                coordinator.draft.directControl.outputFields[index].path?.remove(at: componentIndex)
                                coordinator.draft.definitionDigest = ""
                            }
                            .labelStyle(.iconOnly)
                        }
                    }
                }
                .padding(10)
                .workspaceInset(radius: 8)
            }
            IntentLabHelp("The path starts with the intent result’s value. Add named properties or bounded indexes to select the exact value you want to compare. Display name is only a label.")
        }
    }

    private func append(_ component: ScenarioProjectionPathComponent, to index: Int) {
        coordinator.draft.directControl.outputFields[index].path =
            (coordinator.draft.directControl.outputFields[index].path ?? []) + [component]
        coordinator.draft.definitionDigest = ""
    }

    private func fieldBinding(_ index: Int) -> Binding<ScenarioOutputField> {
        Binding(
            get: { coordinator.draft.directControl.outputFields[index] },
            set: { coordinator.draft.directControl.outputFields[index] = $0; coordinator.draft.definitionDigest = "" }
        )
    }

    private func pathBinding(field: Int, component: Int) -> Binding<ScenarioProjectionPathComponent> {
        Binding(
            get: { coordinator.draft.directControl.outputFields[field].path![component] },
            set: { coordinator.draft.directControl.outputFields[field].path![component] = $0; coordinator.draft.definitionDigest = "" }
        )
    }

    private func optionalText(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func optionalInt(_ value: Binding<Int?>) -> Binding<Int> {
        Binding(get: { value.wrappedValue ?? 0 }, set: { value.wrappedValue = $0 })
    }
}

private enum ProjectionValueChoice: String, CaseIterable, Identifiable {
    case string, boolean, integer, number, date
    case stringArray, booleanArray, integerArray, numberArray

    var id: Self { self }
    var title: String {
        switch self {
        case .string: "Text"
        case .boolean: "Boolean"
        case .integer: "Integer"
        case .number: "Number"
        case .date: "Date"
        case .stringArray: "Text array"
        case .booleanArray: "Boolean array"
        case .integerArray: "Integer array"
        case .numberArray: "Number array"
        }
    }

    init(_ type: ScenarioValueType) {
        switch type {
        case .primitive(.string): self = .string
        case .primitive(.boolean): self = .boolean
        case .primitive(.integer): self = .integer
        case .primitive(.number): self = .number
        case .primitive(.date): self = .date
        case .array(.primitive(.string)): self = .stringArray
        case .array(.primitive(.boolean)): self = .booleanArray
        case .array(.primitive(.integer)): self = .integerArray
        case .array(.primitive(.number)): self = .numberArray
        default: self = .string
        }
    }

    var valueType: ScenarioValueType {
        switch self {
        case .string: .primitive(.string)
        case .boolean: .primitive(.boolean)
        case .integer: .primitive(.integer)
        case .number: .primitive(.number)
        case .date: .primitive(.date)
        case .stringArray: .array(element: .primitive(.string))
        case .booleanArray: .array(element: .primitive(.boolean))
        case .integerArray: .array(element: .primitive(.integer))
        case .numberArray: .array(element: .primitive(.number))
        }
    }
}
