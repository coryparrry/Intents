#if os(macOS)
import SwiftUI
import IntentsAutomationCore

struct AutomationFirstRunControls: View {
    @Bindable var model: AppAutomationStore
    @State private var review: AutomationNativeFirstRunReview?

    var body: some View {
        GroupBox("Run checks") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Start with a read-only observation of your app. Include discovered actions and provide the inputs they need.")
                    .font(.callout).foregroundStyle(.secondary)
                if model.prepared != nil, model.catalog?.systemActions.isEmpty == false {
                    Toggle("Include discovered app actions", isOn: $model.firstRunIncludesActions)
                        .onChange(of: model.firstRunIncludesActions) { model.firstRunEffectsConfirmed = false }
                        .disabled(!model.canEditFirstRunInputs)
                    if model.firstRunIncludesActions {
                        Text("Declared defaults and discovered enum cases are included automatically within the check budget. Actions without enough input evidence remain listed as gaps.")
                            .font(.callout).foregroundStyle(.secondary)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach((model.catalog?.systemActions ?? []).sorted { $0.id < $1.id }) { action in
                                    AutomationFirstRunActionInputs(model: model, action: action)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 280)
                        Picker("Permitted effects", selection: $model.effectChoice) {
                            Text("Choose the actions' effects").tag("")
                            Text("Read-only actions").tag("navigation")
                            Text("Changes to disposable test records").tag("fixture")
                            Text("Changes to this app's data").tag("external")
                        }.onChange(of: model.effectChoice) { model.firstRunEffectsConfirmed = false }
                        if model.effectChoice == "fixture" { Toggle("This is a disposable test environment", isOn: $model.disposable) }
                        Toggle("I confirm these actions stay within the selected effects", isOn: $model.firstRunEffectsConfirmed)
                    }
                }
                Button("Run checks…") {
                    do {
                        let reviewed = try model.reviewFirstChecks()
                        model.firstRunInputReviewID = reviewed.id
                        review = reviewed
                    }
                    catch { model.message = model.errorText(error) }
                }
                .disabled(!model.canReviewFirstChecks || model.firstRunInputReviewID != nil || (model.firstRunIncludesActions && !model.firstRunEffectsConfirmed))
                .accessibilityIdentifier("automation.runFirstChecks")
                if !model.firstRunReports.isEmpty {
                    Text("\(model.firstRunReports.count) saved results. Open the saved cases below to inspect each result.")
                        .font(.callout)
                }
                if !model.firstRunGaps.isEmpty {
                    DisclosureGroup("Checks that need more information") {
                        ForEach(model.firstRunGaps, id: \.self) { gap in Text(gap).font(.callout) }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $review, onDismiss: { model.firstRunInputReviewID = nil }) { reviewed in
            VStack(alignment: .leading, spacing: 16) {
                Text("Run checks in \(reviewed.appName)?").font(.title2)
                Text("Destination: \(reviewed.targetName)")
                Text("Intents will run up to \(reviewed.requests.count) checks. Observations and successful invocation alone do not establish business correctness.")
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(reviewed.requests, id: \.digest) { request in
                            Text(request.plan.execution.operation)
                        }
                        ForEach(reviewed.gaps, id: \.self) { gap in Text(gap).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 240)
                if reviewed.requests.contains(where: \.installApproved) { Text("The selected simulator may be started and this prepared app installed.").font(.callout) }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.firstRunInputReviewID = nil; review = nil }
                    Button(reviewed.requests.isEmpty ? "Keep assessment" : "Run approved checks") {
                        model.firstRunInputReviewID = nil; review = nil; model.runFirstChecks(reviewed)
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 540)
        }
    }
}

private struct AutomationFirstRunActionInputs: View {
    @Bindable var model: AppAutomationStore
    let action: ApplicationSurfaceCatalog.SystemAction

    var body: some View {
        let parameters = model.firstRunInputParameters(for: action)
        if !action.compiled || !action.parametersComplete {
            Text(action.title + ": input declarations are incomplete.").font(.callout).foregroundStyle(.secondary)
        } else if parameters.isEmpty {
            Text(action.title).font(.callout)
        } else {
            DisclosureGroup(action.title) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(parameters, id: \.name) { parameter in
                        input(parameter)
                    }
                }.padding(.top, 6)
            }
        }
    }

    private func rawInput(_ parameter: String) -> Binding<String?> {
        Binding(get: { model.firstRunInputs[action.id]?[parameter] },
                set: { model.setFirstRunInput($0, actionID: action.id, parameter: parameter) })
    }

    @ViewBuilder private func input(_ parameter: ApplicationSurfaceCatalog.SystemAction.Parameter) -> some View {
        if parameter.family == "entity" {
            entityInput(parameter)
        } else if parameter.family == "date" {
            AppAutomationDateInput(name: parameter.name, rawInput: rawInput(parameter.name))
                .disabled(!model.canEditFirstRunInputs)
        } else if parameter.family == "bool" {
            Picker(parameter.name, selection: Binding(get: { model.firstRunInputs[action.id]?[parameter.name] ?? "" },
                set: { model.setFirstRunInput($0.isEmpty ? nil : $0, actionID: action.id, parameter: parameter.name) })) {
                Text("Choose a value").tag("")
                Text("True").tag("true")
                Text("False").tag("false")
            }.disabled(!model.canEditFirstRunInputs)
        } else if let family = parameter.family, family != "intentFile" {
            TextField(parameter.name, text: Binding(get: { model.firstRunInputs[action.id]?[parameter.name] ?? "" },
                set: { model.setFirstRunInput($0, actionID: action.id, parameter: parameter.name) }))
                .disabled(!model.canEditFirstRunInputs)
                .accessibilityIdentifier("automation.firstRun.input." + action.id + "." + parameter.name)
            if AutomationCodecRegistry.arrayFamilies.contains(family) || ["duration", "calendarComponents"].contains(family) {
                Text("Enter the declared " + family + " value as JSON. Invalid values leave this action as a gap.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text(parameter.name + " needs a supported input or saved setup in the advanced workflow.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func entityInput(_ parameter: ApplicationSurfaceCatalog.SystemAction.Parameter) -> some View {
        if let entity = model.entityDefinition(parameter) {
            if !entity.usesSuggestedQuery {
                TextField("Find " + parameter.name + " by name or description", text: Binding(
                    get: { model.firstRunEntityQueryTexts[action.id]?[parameter.name] ?? "" },
                    set: { model.setFirstRunEntityQueryText($0, actionID: action.id, parameter: parameter.name) }))
                    .disabled(!model.canEditFirstRunInputs)
                    .accessibilityIdentifier("automation.firstRun.query." + action.id + "." + parameter.name)
            }
            Button(entity.usesSuggestedQuery ? "Read suggested records" : "Read matching records") { Task { await model.findFirstRunEntities(actionID: action.id, parameter: parameter) } }
                .disabled(!model.canFindFirstRunEntities(actionID: action.id, parameter: parameter))
                .accessibilityIdentifier("automation.firstRun.find." + action.id + "." + parameter.name)
            let choices = model.firstRunEntityChoices[action.id]?[parameter.name] ?? []
            let labelCounts = Dictionary(grouping: choices, by: { AutomationNativeEntitySelection.label($0, entity: entity) }).mapValues { $0.count }
            if !choices.isEmpty {
                Picker(parameter.name, selection: Binding(
                    get: { model.firstRunSelectedEntityIDs[action.id]?[parameter.name] ?? "" },
                    set: { model.selectFirstRunEntity($0, actionID: action.id, parameter: parameter.name) })) {
                    Text("Choose a returned record").tag("")
                    ForEach(choices) { choice in
                        Text(choiceLabel(choice, entity: entity, labelCounts: labelCounts)).tag(choice.id)
                    }
                }.disabled(!model.canEditFirstRunInputs)
            }
            Text("This reads real records. The selected record is looked up again when the action runs.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text(parameter.name + " has no discovered read-only query. Use a qualified setup in the advanced workflow.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func choiceLabel(_ choice: AutomationQueryEntityChoice, entity: ApplicationSurfaceCatalog.Entity,
                             labelCounts: [String: Int]) -> String {
        let label = AutomationNativeEntitySelection.label(choice, entity: entity)
        if label.isEmpty { return choice.id }
        if (labelCounts[label] ?? 0) > 1 {
            return label + " (" + choice.id + ")"
        }
        return label
    }
}
#if DEBUG
#Preview("Automatic checks") {
    AutomationFirstRunControls(model: AppAutomationStore(supportDirectory: URL(fileURLWithPath: "/private/tmp/intents-first-checks-preview")))
        .padding(24).frame(width: 620)
}
#endif
#endif
