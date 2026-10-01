import SwiftUI

struct ScenarioEditorView: View {
    @Bindable var coordinator: ScenarioCoordinator
    let projects: [EvaluationProject]
    @State private var pendingTest: ScenarioDefinition?
    @State private var confirmingDraftReplacement = false


    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create a test").font(.title3.weight(.semibold))
                    Text("Describe the request and the result you expect.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Menu("Saved tests") {
                    ForEach(coordinator.definitions.indices, id: \.self) { index in
                        let definition = coordinator.definitions[index]
                        Button("\(definition.name) · v\(definition.version)") {
                            requestTest(definition)
                        }
                    }
                }
                .disabled(coordinator.definitions.isEmpty || coordinator.isRunning || coordinator.isDiscoveringConnection || coordinator.isVerifyingIntegration)
                Button("New test", systemImage: "plus") { requestTest(nil) }
                    .disabled(coordinator.isRunning || coordinator.isDiscoveringConnection || coordinator.isVerifyingIntegration)
                Button("Save test", systemImage: "square.and.arrow.down") {
                    Task {
                        do { try await coordinator.freezeAndSave() }
                        catch { coordinator.notice = error.localizedDescription }
                    }
                }
                .disabled(coordinator.isRunning || coordinator.isDiscoveringConnection || coordinator.isVerifyingIntegration)
            }
            outcomeSection
            evidenceSection
            DisclosureGroup("Inputs · \(coordinator.draft.directControl.parameters.count)") {
                parametersSection.padding(.top, 12)
            }
            DisclosureGroup("Result checks · \(coordinator.draft.assertions.count)") {
                assertionsSection.padding(.top, 12)
            }
            validationSummary
            DisclosureGroup("Test data and advanced settings") {
                VStack(spacing: 16) {
                    fixtureSection
                    settingsSection
                }.padding(.top, 12)
            }
        }
        .textFieldStyle(.roundedBorder)
        .confirmationDialog("Replace the current draft?", isPresented: $confirmingDraftReplacement) {
            Button("Discard draft and continue", role: .destructive) { openPendingTest() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your unsaved edits will be lost. Previously saved tests and results are kept.")
        }
        .onChange(of: coordinator.draft.safety.mutationPolicy) { _, policy in
            if policy == .syntheticMutation { coordinator.draft.coverage.siriAttemptCount = 1 }
        }
    }

    private func requestTest(_ definition: ScenarioDefinition?) {
        pendingTest = definition
        if !coordinator.definitions.contains(coordinator.draft)
            || !coordinator.invalidParameterDraftIndices.isEmpty {
            confirmingDraftReplacement = true
        } else {
            openPendingTest()
        }
    }

    private func openPendingTest() {
        if let definition = pendingTest {
            Task { await coordinator.selectSavedDefinition(id: definition.id, version: definition.version) }
        } else {
            coordinator.startReusableCheck()
        }
    }

    private var outcomeSection: some View {
        IntentLabCard(
            "What should happen?",
            subtitle: "Describe success, then add result checks to verify it."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                labeledRow("Test name", help: "Give this test a name you’ll recognize.", showsHelp: false) {
                    TextField("Test name", text: $coordinator.draft.name)
                }
                labeledRow("Request", help: "The exact words to use when testing Siri.", showsHelp: false) {
                    TextField("For example, open the packing note", text: $coordinator.draft.goal.requestText, axis: .vertical)
                        .lineLimit(2...4)
                }
                labeledRow("Expected result", help: "Describe a visible result. Add result checks below to verify it automatically.", showsHelp: false) {
                    TextField("For example, the packing note opens", text: $coordinator.draft.goal.expectedBehavior, axis: .vertical)
                        .lineLimit(2...5)
                }
                labeledRow("App action", help: "The action’s code name from your app, for example OpenNoteIntent.", showsHelp: false) {
                    TextField("OpenNoteIntent", text: $coordinator.draft.directControl.intentIdentifier)
                }
                DisclosureGroup("App and language details") {
                    VStack(alignment: .leading, spacing: 12) {
                labeledRow("Project", help: "Choose the project whose release report should include this scenario. Changing a saved scenario creates a new frozen version.") {
                    Picker("Project", selection: Binding(
                        get: { coordinator.draft.projectID?.uuidString ?? "" },
                        set: { value in
                            guard let id = UUID(uuidString: value) else { return }
                            coordinator.assignProject(id: id)
                        }
                    )) {
                        Text("Choose project").tag("")
                        ForEach(projects.filter { !$0.isArchived }) { project in
                            Text(project.name).tag(project.id.uuidString)
                        }
                    }
                    .labelsHidden()
                }
                labeledRow("App bundle ID", help: "The unique identifier of the app being tested, such as com.example.Notes. Setup can fill this in from your Xcode project.") {
                    TextField("com.example.App", text: $coordinator.draft.target.bundleIdentifier)
                }
                labeledRow("Language", help: "The language tag for this scenario, such as en-GB for British English. This does not change the iPhone’s Siri language.") {
                    TextField("en-GB", text: $coordinator.draft.goal.languageCode)
                }
                    }.padding(.top, 10)
                }
            }
        }
    }

    private var fixtureSection: some View {
        IntentLabCard("Test data and integration", subtitle: "Choose the intent to invoke and the test data it uses.") {
            VStack(alignment: .leading, spacing: 10) {
                labeledRow("Fixture ID", help: "A fixture is a known set of test data, such as a collection containing a packing note. Use the ID your app’s test support expects.") {
                    TextField("packing-notes", text: $coordinator.draft.fixture.id)
                }
                labeledRow("Fixture version", help: "The version of that test data. Change it when the prepared data changes.") {
                    TextField("1", text: $coordinator.draft.fixture.version)
                }
                labeledRow("Fixture digest", help: "A fingerprint identifying this version of the test data for comparisons. Copy it from your test setup; Intent Lab does not calculate or verify the data’s contents here.") {
                    TextField("Stable fixture digest", text: $coordinator.draft.fixture.digest)
                }
                if coordinator.draft.schemaVersion == ScenarioDefinition.reusableSchemaVersion {
                    ScenarioResultProjectionEditor(coordinator: coordinator)
                }
                labeledRow("Invocation route", help: "App Shortcut describes a shortcut your app exposes. App Intent definition describes the action directly. This records the intended route; it does not create a shortcut or change how this test invokes the action.") {
                    Picker("Invocation route", selection: $coordinator.draft.target.route) {
                        Text("App Shortcut").tag(ScenarioInvocationRoute.appShortcut)
                        Text("App Intent definition").tag(ScenarioInvocationRoute.appIntentDefinition)
                    }
                    .labelsHidden()
                }
                labeledRow("Synthetic fixture", help: "Turn on only for made-up test data. This declaration does not create or isolate the data for you.") {
                    Toggle("Synthetic fixture", isOn: $coordinator.draft.fixture.isSynthetic)
                        .labelsHidden()
                }
                labeledRow("Fixture preparation", help: coordinator.draft.schemaVersion == ScenarioDefinition.reusableSchemaVersion
                    ? "Choose a compiled preparation operation from the integration declaration. The runner calls it before each attempt; your test support must establish the fixture."
                    : "The name of the intended preparation operation, for example resetFixture. Your test support must implement the reset; entering a name does not run that operation.") {
                    TextField("resetFixture", text: $coordinator.draft.fixture.preparationOperation)
                }
                labeledRow("Fixture cleanup", help: coordinator.draft.schemaVersion == ScenarioDefinition.reusableSchemaVersion
                    ? "Choose a compiled cleanup operation from the integration declaration. The runner calls it after each returned attempt; your test support must restore and verify the fixture. Interrupted tests may require recovery."
                    : "The name of the intended cleanup operation, for example resetFixture. Your test support must restore the data; entering a name does not run that operation.") {
                    TextField("resetFixture", text: $coordinator.draft.fixture.cleanupOperation)
                }
                labeledRow("Linked feature run", help: "Optional: paste the UUID of a saved app-feature test run to reuse its evidence. Leave empty if you are not linking one.") {
                    TextField("Optional feature run UUID", text: linkedFeatureRunID)
                }
                labeledRow("Feature ID", help: "When App feature is Required, enter the feature ID recorded by the linked evaluation run. This prevents evidence from a different feature being accepted.") {
                    TextField("Feature ID from the evaluation", text: $coordinator.draft.directControl.linkedFeatureID)
                }
                labeledRow("Feature evidence digest", help: "When App feature is Required, enter the subject-evidence digest from the linked evaluation run. This is separate from the fixture digest above.") {
                    TextField("Digest from the evaluation", text: $coordinator.draft.directControl.linkedFeatureSubjectDigest)
                }
            }
            .textFieldStyle(.roundedBorder)

        }
    }

    private var evidenceSection: some View {
        IntentLabCard("What should this test check?", subtitle: "Choose the parts to include. Required parts decide whether this test passes.") {
            VStack(alignment: .leading, spacing: 14) {
                requirementPickers
                if coordinator.draft.schemaVersion == ScenarioDefinition.reusableSchemaVersion {
                    Divider()
                    Text(ScenarioReportPresentation.checkScope(for: coordinator.draft))
                        .font(.callout).foregroundStyle(.secondary)
                    DisclosureGroup("Verification options") {
                        ScenarioReusableChecksView(coordinator: coordinator).padding(.top, 8)
                    }
                }
                IntentLabHelp("Optional parts are recorded separately. An optional failure can still fail the Xcode run.")
            }

        }
    }

    private var parametersSection: some View {
        IntentLabCard("Inputs", subtitle: "Parameters are inputs the action needs, such as which note to open. Match the names and types declared by the app’s intent. If the action takes no inputs, leave this list empty.") {
            HStack {
                Spacer()
                Button("Add parameter", systemImage: "plus") {
                    coordinator.draft.directControl.parameters.append(
                        .init(name: "parameter", type: .primitive(.string), isOptional: false, presence: .missing)
                    )
                    coordinator.draft.definitionDigest = ""
                }
                .buttonStyle(.borderless)
            }
            ForEach(Array(coordinator.draft.directControl.parameters.indices), id: \.self) { index in
                ScenarioParameterEditor(coordinator: coordinator, index: index, parameter: $coordinator.draft.directControl.parameters[index]) {
                    coordinator.draft.directControl.parameters.remove(at: index)
                    coordinator.invalidParameterDraftIndices = Set(coordinator.invalidParameterDraftIndices.compactMap { draftIndex in
                        draftIndex == index ? nil : (draftIndex > index ? draftIndex - 1 : draftIndex)
                    })
                    coordinator.parameterArrayDraftTexts = Dictionary(uniqueKeysWithValues:
                        coordinator.parameterArrayDraftTexts.compactMap { draftIndex, text in
                            draftIndex == index ? nil : (draftIndex > index ? draftIndex - 1 : draftIndex, text)
                        }
                    )
                    coordinator.draft.definitionDigest = ""
                }
            }

        }
    }

    private var assertionsSection: some View {
        IntentLabCard("Result checks", subtitle: "An assertion is a check that compares what happened with what you expected. For example, check that the returned note ID matches the packing note’s ID.") {
            HStack {
                Spacer()
                Button("Add result check", systemImage: "plus") {
                    coordinator.draft.assertions.append(
                        .init(
                            kind: .returnedField,
                            observationKey: "observation",
                            expectedValue: .string(""),
                            explanation: "Describe what this observation proves."
                        ))
                    coordinator.draft.definitionDigest = ""
                }
                .buttonStyle(.borderless)
            }
            ForEach($coordinator.draft.assertions) { $assertion in
                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            assertionControls(assertion: $assertion)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            assertionControls(assertion: $assertion)
                        }
                    }
                    IntentLabHelp(IntentLabGuidance.assertion(assertion.kind))
                    IntentLabHelp("Observation key is the exact name your test support gives a captured result, such as noteID. Required checks must pass for their lane to pass; unchecked checks are still reported. New checks apply to both Intent integration and Siri, so both need to capture the key.")
                    ScenarioExpectedValueEditor(value: $assertion.expectedValue)
                    IntentLabHelp("Expected value: Text is words or an ID; Boolean is true or false; Integer is a whole number; Number can include decimals. None supplies no exact value and cannot pass a required exact-value check.")
                    TextField("What this proves", text: $assertion.explanation)
                    IntentLabHelp("Explain why this check matters. For Semantic review, write the criteria a reviewer should use.")
                }
                .padding(10)
                .workspaceInset(radius: 8)
            }

        }
    }

    private var settingsSection: some View {
        IntentLabCard("Run settings", subtitle: "Configure safety, attempts and saved versions.") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Safety", selection: $coordinator.draft.safety.mutationPolicy) {
                        Text("Read-only").tag(ScenarioMutationPolicy.readOnly)
                        Text("Change test data").tag(ScenarioMutationPolicy.syntheticMutation)
                    }
                    IntentLabHelp(coordinator.draft.schemaVersion == ScenarioDefinition.reusableSchemaVersion
                        ? "Read-only actions should leave data unchanged. Changing test data requires a synthetic fixture and limits Siri to one attempt. The runner calls declared preparation and cleanup operations, but your app must enforce allowed actions and verify its cleanup. Interrupted tests may require recovery."
                        : "Read-only is for actions that should leave data unchanged. Change test data requires a synthetic fixture and a list of allowed actions, and limits Siri to one attempt. These are declarations: the current runner does not enforce the action list. Use app-side safeguards for changes and cleanup.")
                    Picker("Case set", selection: $coordinator.draft.caseSet) {
                        Text("Regression").tag(ScenarioCaseSet?.some(.regression))
                        Text("Holdout").tag(ScenarioCaseSet?.some(.holdout))
                    }
                    IntentLabHelp("Regression labels a repeatable check for previously working behavior. Holdout labels a case kept aside for later evaluation. These labels do not change how the test runs.")
                    Stepper("Siri attempts: \(siriAttemptCount.wrappedValue)", value: siriAttemptCount, in: 1...3)
                        .disabled(coordinator.draft.safety.mutationPolicy == .syntheticMutation)
                    IntentLabHelp("Repeat the same Siri request 1–3 times to see whether it behaves consistently. Each attempt is reported separately. An unresolved attempt can stop later attempts.")
                }
                HStack(spacing: 12) {
                    TextField(
                        "Deadline (seconds)",
                        value: $coordinator.draft.safety.deadlineSeconds,
                        format: .number.precision(.fractionLength(0))
                    )
                    .frame(maxWidth: 190)
                    TextField("Allowed actions, comma separated", text: allowedActions)
                }
                IntentLabHelp("Deadline limits how long each intent or Siri action waits, in seconds. Building and setup take additional time. Allowed actions lists intended operation names, separated by commas; required when changing test data. This list documents permission; the app’s test support must enforce it.")
                TextField(
                    "Intentional comparison changes for next run, comma separated",
                    text: statedChangedDimensions
                )
                IntentLabHelp("Comparison changes: usually leave empty. List only differences you intend to allow when comparing runs, using exact names such as appBuild or language. These differences will be treated as compatible.")
                IntentLabHelp("Saving keeps a fixed version for repeatable runs. Changes to a saved test create a new version automatically.")
                Button("Start a new version") { coordinator.duplicateAsNewVersion() }
            }

            requestSuggestions
        }
    }

    @ViewBuilder private var requirementPickers: some View {
        requirementPicker("App action", explanation: "Run the action directly, without Siri.", selection: $coordinator.draft.coverage.intentIntegration)
        requirementPicker("Siri", explanation: "Send the request text to Siri on your iPhone.", selection: $coordinator.draft.coverage.siri)
        requirementPicker("App evaluation", explanation: "Reuse a saved evaluation linked in advanced settings.", selection: $coordinator.draft.coverage.appFeature)
    }

    @ViewBuilder private func assertionControls(assertion: Binding<ScenarioAssertion>) -> some View {
        Picker("Kind", selection: assertion.kind) {
            ForEach(ScenarioAssertionKind.allCases, id: \.self) {
                Text(assertionTitle($0)).tag($0)
            }
        }
        TextField("Observation key", text: assertion.observationKey)
        Toggle("Required", isOn: assertion.required)
        Button("Remove", systemImage: "trash", role: .destructive) {
            coordinator.draft.assertions.removeAll { $0.id == assertion.wrappedValue.id }
            coordinator.draft.definitionDigest = ""
        }
        .labelStyle(.iconOnly)
    }

    private var validationSummary: some View {
        let issues = coordinator.currentValidationIssues
        return Group {
            if !issues.isEmpty {
                DisclosureGroup("Before you run · \(issues.count) items to review") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(issues) { issue in
                            Label(issue.message, systemImage: issue.severity == .error ? "xmark.circle" : "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(issue.severity == .error ? .red : .orange)
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    private var requestSuggestions: some View {
        DisclosureGroup("Explore request wording") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Foundation Models generates review candidates only. Nothing is added to the regression scenario until you approve it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(
                    coordinator.isGeneratingSuggestions ? "Generating…" : "Generate candidates",
                    systemImage: "text.bubble"
                ) {
                    Task { await coordinator.generateSuggestions() }
                }
                .disabled(coordinator.isGeneratingSuggestions)
                ForEach(coordinator.suggestions) { suggestion in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(suggestion.requestText).font(.callout.weight(.medium))
                            Text("\(suggestion.category) · \(suggestion.note)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(suggestion.approved ? "Approved" : "Use") {
                            coordinator.approveSuggestion(id: suggestion.id)
                        }
                        .disabled(suggestion.approved)
                    }
                    .padding(10)
                    .workspaceInset(radius: 8)
                }
            }
            .padding(.top, 6)
        }
    }

    private func labeledRow<Content: View>(_ title: String, help: String, showsHelp: Bool = true, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                content().help(help)
                if showsHelp { IntentLabHelp(help) }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }

    private func requirementPicker(_ title: String, explanation: String, selection: Binding<ScenarioLaneRequirement>) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(explanation).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Picker(title, selection: selection) {
                Text("Required").tag(ScenarioLaneRequirement.required)
                Text("Optional").tag(ScenarioLaneRequirement.optional)
                Text("Not included").tag(ScenarioLaneRequirement.notApplicable)
            }
            .labelsHidden()
            .frame(width: 150)
        }
    }

    private func assertionTitle(_ kind: ScenarioAssertionKind) -> String {
        switch kind {
        case .entityIdentifier: "Entity ID"
        case .returnedField: "Returned field"
        case .visibleText: "Visible text"
        case .stateTransition: "State change"
        case .noMutation: "No mutation"
        case .semanticRubric: "Semantic review"
        }
    }

    private var linkedFeatureRunID: Binding<String> {
        Binding(
            get: { coordinator.draft.directControl.linkedFeatureRunID?.uuidString ?? "" },
            set: { text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                coordinator.draft.directControl.linkedFeatureRunID = trimmed.isEmpty ? nil : UUID(uuidString: trimmed)
            }
        )
    }

    private var allowedActions: Binding<String> {
        Binding(
            get: { coordinator.draft.safety.allowedActions.joined(separator: ", ") },
            set: { text in
                coordinator.draft.safety.allowedActions = text.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private var statedChangedDimensions: Binding<String> {
        Binding(
            get: { coordinator.statedChangedDimensions.sorted().joined(separator: ", ") },
            set: { text in
                coordinator.statedChangedDimensions = Set(
                    text.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                )
            }
        )
    }

    private var siriAttemptCount: Binding<Int> {
        Binding(
            get: { coordinator.draft.coverage.siriAttemptCount ?? 3 },
            set: { coordinator.draft.coverage.siriAttemptCount = $0 }
        )
    }
}

private struct ScenarioParameterEditor: View {
    @Bindable var coordinator: ScenarioCoordinator
    let index: Int
    @Binding var parameter: ScenarioParameter
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ViewThatFits(in: .horizontal) {
                HStack { parameterControls }
                VStack(alignment: .leading, spacing: 8) { parameterControls }
            }
            IntentLabHelp("Name must match the input declared by the intent. Optional means the intent accepts an absent value; it does not make a required input optional in your app’s code.")
            IntentLabHelp(typeSelection.wrappedValue.explanation)
            IntentLabHelp("Missing leaves the input unset. Set value supplies the value below. Explicit null deliberately clears an optional input.")
            valueEditor
        }
        .padding(10)
        .workspaceInset(radius: 8)
    }

    @ViewBuilder private var parameterControls: some View {
        TextField("Parameter name", text: $parameter.name)
        Picker("Type", selection: typeSelection) {
            ForEach(ParameterEditorType.allCases) { type in Text(type.title).tag(type) }
        }
        .accessibilityIdentifier("Parameter type")
        Toggle("Optional", isOn: $parameter.isOptional)
        Picker("Presence", selection: presenceSelection) {
            Text("Missing").tag(ParameterPresenceChoice.missing)
            Text("Set value").tag(ParameterPresenceChoice.value)
            Text("Explicit null").tag(ParameterPresenceChoice.null)
        }
        .accessibilityIdentifier("Parameter presence")
        Button("Remove", systemImage: "trash", role: .destructive, action: remove)
            .labelStyle(.iconOnly)
            .accessibilityIdentifier("Remove parameter")
    }

    @ViewBuilder private var valueEditor: some View {
        if case .missing = parameter.presence {
            Text("No value is supplied. The intent uses its default, if it has one, or handles the missing input.")
                .font(.caption).foregroundStyle(.secondary)
        } else if case .value(.null) = parameter.presence {
            Text(parameter.isOptional
                 ? "The input is explicitly set to no value (nil)."
                 : "Explicit null requires an optional parameter.")
                .font(.caption)
                .foregroundStyle(parameter.isOptional ? Color.secondary : Color.red)
        } else {
            switch parameter.type {
            case .primitive(.string):
                TextField("String value", text: stringValue)
            case .primitive(.boolean):
                Toggle("Boolean value", isOn: boolValue)
            case .primitive(.integer):
                TextField("Integer value", value: integerValue, format: .number)
            case .primitive(.number):
                TextField("Finite number", value: numberValue, format: .number)
            case .primitive(.date):
                DatePicker("Resolved instant", selection: dateValue)
            case .enumeration:
                HStack {
                    TextField("Enum type identifier", text: enumTypeIdentifier)
                    TextField("Allowed cases, comma separated", text: enumAllowedCases)
                    Picker("Enum case", selection: enumValue) {
                        ForEach(enumCases, id: \.self) { Text($0).tag($0) }
                    }
                }
            case .entity:
                HStack {
                    TextField("Entity type identifier", text: entityTypeIdentifier)
                    TextField("Stable entity identifier", text: entityValue)
                }
            case .array:
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Array item type", selection: arrayElementSelection) {
                        Text("String").tag(ParameterEditorType.string)
                        Text("Boolean").tag(ParameterEditorType.boolean)
                        Text("Integer").tag(ParameterEditorType.integer)
                        Text("Number").tag(ParameterEditorType.number)
                    }
                    .accessibilityIdentifier("Array item type")
                    TextField("Comma-separated values", text: arrayValues)
                    if coordinator.invalidParameterDraftIndices.contains(index) {
                        Text("Finish each item before saving or running this scenario.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Text("All items must have the same type. Enter values separated by commas; Boolean values must be true or false. Invalid values are rejected before Xcode runs.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var presenceSelection: Binding<ParameterPresenceChoice> {
        Binding(
            get: {
                switch parameter.presence {
                case .missing: .missing
                case .value(.null): .null
                case .value: .value
                }
            },
            set: { choice in
                switch choice {
                case .missing: parameter.presence = .missing
                case .value: parameter.presence = defaultPresence(for: parameter.type)
                case .null: parameter.presence = .value(.null)
                }
                clearArrayDraft()
            }
        )
    }

    private var typeSelection: Binding<ParameterEditorType> {
        Binding(
            get: { ParameterEditorType(parameter.type) },
            set: { newValue in
                parameter.type = newValue.valueType
                parameter.presence = .missing
                clearArrayDraft()
            }
        )
    }

    private var stringValue: Binding<String> { valueBinding(default: "", get: { if case .string(let value) = $0 { value } else { nil } }, wrap: ScenarioValue.string) }
    private var boolValue: Binding<Bool> { valueBinding(default: false, get: { if case .boolean(let value) = $0 { value } else { nil } }, wrap: ScenarioValue.boolean) }
    private var integerValue: Binding<Int64> { valueBinding(default: 0, get: { if case .integer(let value) = $0 { value } else { nil } }, wrap: ScenarioValue.integer) }
    private var numberValue: Binding<Double> { valueBinding(default: 0, get: { if case .number(let value) = $0 { value } else { nil } }, wrap: ScenarioValue.number) }
    private var dateValue: Binding<Date> {
        valueBinding(default: Date(), get: { if case .date(let value) = $0 { value.resolvedInstant } else { nil } }) {
            .date(.init(source: ISO8601DateFormatter().string(from: $0), timeZoneIdentifier: TimeZone.current.identifier, resolvedInstant: $0))
        }
    }
    private var enumValue: Binding<String> {
        let typeIdentifier: String
        let first: String
        if case .enumeration(let type, let cases) = parameter.type {
            typeIdentifier = type
            first = cases.first ?? "case"
        } else { typeIdentifier = "Enum"; first = "case" }
        return valueBinding(default: first, get: { if case .enumeration(let value) = $0 { value.caseIdentifier } else { nil } }) {
            .enumeration(.init(typeIdentifier: typeIdentifier, caseIdentifier: $0))
        }
    }
    private var enumCases: [String] {
        guard case .enumeration(_, let cases) = parameter.type else { return [] }
        return cases
    }
    private var enumTypeIdentifier: Binding<String> {
        Binding(
            get: { if case .enumeration(let type, _) = parameter.type { type } else { "" } },
            set: { newValue in
                guard case .enumeration(_, let cases) = parameter.type else { return }
                parameter.type = .enumeration(typeIdentifier: newValue, allowedCases: cases)
                if case .value(.enumeration(var value)) = parameter.presence {
                    value.typeIdentifier = newValue
                    parameter.presence = .value(.enumeration(value))
                }
            }
        )
    }
    private var enumAllowedCases: Binding<String> {
        Binding(
            get: { enumCases.joined(separator: ", ") },
            set: { text in
                guard case .enumeration(let type, _) = parameter.type else { return }
                let cases = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                parameter.type = .enumeration(typeIdentifier: type, allowedCases: cases)
                if case .value(.enumeration(let value)) = parameter.presence, !cases.contains(value.caseIdentifier) {
                    parameter.presence = .value(.enumeration(.init(typeIdentifier: type, caseIdentifier: cases.first ?? "")))
                }
            }
        )
    }
    private var entityTypeIdentifier: Binding<String> {
        Binding(
            get: { if case .entity(let type) = parameter.type { type } else { "" } },
            set: { newValue in
                parameter.type = .entity(typeIdentifier: newValue)
                if case .value(.entity(var value)) = parameter.presence {
                    value.typeIdentifier = newValue
                    parameter.presence = .value(.entity(value))
                }
            }
        )
    }
    private var entityValue: Binding<String> {
        let typeIdentifier = if case .entity(let type) = parameter.type { type } else { "Entity" }
        return valueBinding(default: "", get: { if case .entity(let value) = $0 { value.identifier } else { nil } }) {
            .entity(.init(typeIdentifier: typeIdentifier, identifier: $0))
        }
    }

    private var arrayElementSelection: Binding<ParameterEditorType> {
        Binding(
            get: {
                guard case .array(let element) = parameter.type else { return .string }
                return ParameterEditorType(element)
            },
            set: { selection in
                let element = selection.valueType
                parameter.type = .array(element: element)
                parameter.presence = .value(.array([]))
                clearArrayDraft()
            }
        )
    }

    private var arrayValues: Binding<String> {
        Binding(
            get: {
                if let draft = coordinator.parameterArrayDraftTexts[index] { return draft }
                guard case .value(.array(let values)) = parameter.presence else { return "" }
                return values.map { value in
                    switch value {
                    case .string(let item): item
                    case .boolean(let item): String(item)
                    case .integer(let item): String(item)
                    case .number(let item): String(item)
                    default: ""
                    }
                }.joined(separator: ", ")
            },
            set: { text in
                guard case .array(let element) = parameter.type else { return }
                coordinator.parameterArrayDraftTexts[index] = text
                guard let values = ScenarioArrayInput.parse(text, element: element) else {
                    coordinator.invalidParameterDraftIndices.insert(index)
                    return
                }
                parameter.presence = .value(.array(values))
                coordinator.invalidParameterDraftIndices.remove(index)
            }
        )
    }

    private func clearArrayDraft() {
        coordinator.parameterArrayDraftTexts.removeValue(forKey: index)
        coordinator.invalidParameterDraftIndices.remove(index)
    }

    private func valueBinding<Value>(
        default defaultValue: Value,
        get: @escaping (ScenarioValue) -> Value?,
        wrap: @escaping (Value) -> ScenarioValue
    ) -> Binding<Value> {
        Binding(
            get: {
                guard case .value(let value) = parameter.presence else { return defaultValue }
                return get(value) ?? defaultValue
            },
            set: { parameter.presence = .value(wrap($0)) }
        )
    }

    private func defaultPresence(for type: ScenarioValueType) -> ScenarioParameterPresence {
        switch type {
        case .primitive(.string): .value(.string(""))
        case .primitive(.boolean): .value(.boolean(false))
        case .primitive(.integer): .value(.integer(0))
        case .primitive(.number): .value(.number(0))
        case .primitive(.date):
            .value(.date(.init(
                source: ISO8601DateFormatter().string(from: Date()),
                timeZoneIdentifier: TimeZone.current.identifier,
                resolvedInstant: Date()
            )))
        case .enumeration(let type, let cases):
            .value(.enumeration(.init(typeIdentifier: type, caseIdentifier: cases.first ?? "case")))
        case .entity(let type): .value(.entity(.init(typeIdentifier: type, identifier: "")))
        case .array: .value(.array([]))
        }
    }
}

enum ScenarioArrayInput {
    static func parse(_ text: String, element: ScenarioValueType) -> [ScenarioValue]? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let parsed: [ScenarioValue?] = parts.map { item in
            switch element {
            case .primitive(.string): .string(item)
            case .primitive(.boolean): Bool(item).map(ScenarioValue.boolean)
            case .primitive(.integer): Int64(item).map(ScenarioValue.integer)
            case .primitive(.number): Double(item).map(ScenarioValue.number)
            default: nil
            }
        }
        guard parsed.allSatisfy({ $0 != nil }) else { return nil }
        return parsed.compactMap { $0 }
    }
}

private enum ParameterPresenceChoice: Hashable { case missing, value, null }

private struct ScenarioExpectedValueEditor: View {
    @Binding var value: ScenarioValue?

    var body: some View {
        HStack {
            Picker("Expected value type", selection: valueType) {
                Text("None").tag(ExpectedValueType.none)
                Text("Text").tag(ExpectedValueType.string)
                Text("Boolean").tag(ExpectedValueType.boolean)
                Text("Integer").tag(ExpectedValueType.integer)
                Text("Number").tag(ExpectedValueType.number)
            }
            .fixedSize(horizontal: true, vertical: false)
            switch valueType.wrappedValue {
            case .none:
                Text("No exact value to compare").foregroundStyle(.secondary)
            case .string:
                TextField("Expected text or stable ID", text: stringValue)
            case .boolean:
                Toggle("Expected", isOn: boolValue)
            case .integer:
                TextField("Expected integer", value: integerValue, format: .number)
            case .number:
                TextField("Expected number", value: numberValue, format: .number)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private var valueType: Binding<ExpectedValueType> {
        Binding(
            get: {
                switch value {
                case nil: .none
                case .string, .entity, .enumeration, .date, .array, .null: .string
                case .boolean: .boolean
                case .integer: .integer
                case .number: .number
                }
            },
            set: { type in
                switch type {
                case .none: value = nil
                case .string: value = .string("")
                case .boolean: value = .boolean(false)
                case .integer: value = .integer(0)
                case .number: value = .number(0)
                }
            }
        )
    }

    private var stringValue: Binding<String> {
        Binding(
            get: {
                switch value {
                case .string(let item): item
                case .entity(let item): item.identifier
                case .enumeration(let item): item.caseIdentifier
                case .date(let item): item.source
                case .array(let items): "\(items.count) values"
                case .null: "null"
                default: ""
                }
            },
            set: { value = .string($0) }
        )
    }
    private var boolValue: Binding<Bool> { scalar(default: false, get: { if case .boolean(let item) = $0 { item } else { nil } }, wrap: ScenarioValue.boolean) }
    private var integerValue: Binding<Int64> { scalar(default: 0, get: { if case .integer(let item) = $0 { item } else { nil } }, wrap: ScenarioValue.integer) }
    private var numberValue: Binding<Double> { scalar(default: 0, get: { if case .number(let item) = $0 { item } else { nil } }, wrap: ScenarioValue.number) }

    private func scalar<T>(default defaultValue: T, get: @escaping (ScenarioValue) -> T?, wrap: @escaping (T) -> ScenarioValue) -> Binding<T> {
        Binding(get: { value.flatMap(get) ?? defaultValue }, set: { value = wrap($0) })
    }
}

private enum ExpectedValueType: Hashable { case none, string, boolean, integer, number }

private enum ParameterEditorType: String, CaseIterable, Identifiable {
    case string, boolean, integer, number, date, enumeration, entity, array
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var explanation: String {
        switch self {
        case .string: "String is text, such as a note title."
        case .boolean: "Boolean is a true-or-false value. Turn the switch on for true or off for false."
        case .integer: "Integer is a whole number, such as an item count of 3."
        case .number: "Number can include decimals, such as 2.5."
        case .date: "Date is a specific date and time. Choose the exact moment the action should receive."
        case .enumeration: "Enumeration is one choice from a fixed list. Enter the enum’s code identifier and allowed case identifiers, then choose a case."
        case .entity: "Entity is an item in your app, such as a note. Enter its type identifier and the item’s stable ID from your test data."
        case .array: "Array is a list of values of the same type. Choose the item type, then enter the list."
        }
    }

    init(_ type: ScenarioValueType) {
        switch type {
        case .primitive(.string): self = .string
        case .primitive(.boolean): self = .boolean
        case .primitive(.integer): self = .integer
        case .primitive(.number): self = .number
        case .primitive(.date): self = .date
        case .enumeration: self = .enumeration
        case .entity: self = .entity
        case .array: self = .array
        }
    }

    var valueType: ScenarioValueType {
        switch self {
        case .string: .primitive(.string)
        case .boolean: .primitive(.boolean)
        case .integer: .primitive(.integer)
        case .number: .primitive(.number)
        case .date: .primitive(.date)
        case .enumeration: .enumeration(typeIdentifier: "Enum", allowedCases: ["case"])
        case .entity: .entity(typeIdentifier: "Entity")
        case .array: .array(element: .primitive(.string))
        }
    }
}
