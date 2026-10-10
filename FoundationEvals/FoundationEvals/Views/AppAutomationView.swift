import SwiftUI
import AppKit
import IntentsAutomationCore

struct AppAutomationView: View {
    @Bindable var model: AppAutomationStore
    @State private var savedCaseLimit = 50
    @State private var approveBuild = false
    @State private var preparationReview: AutomationNativePreparationReview?
    @State private var searchReview: AutomationNativeSearchReview?
    @State private var approveRun = false
    @State private var nativeConfirmation: AutomationNativeConfirmationReview?
    @State private var nativeConfirmationLoading = false
    @State private var approveSearch = false
    @State private var approveReproduction = false
    @State private var approveComparison = false
    @State private var macWorkflowReview: AutomationNativeMacWorkflowReview?
    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("App automation").font(.largeTitle.bold())
                        Text("Choose your app, run a workflow, and inspect the evidence.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose app…") { chooseApp() }.disabled(model.busy)
                }
                if let unresolved = model.retainedUnresolvedNormalReport {
                    Text("Attempt " + unresolved.attemptID + " has unresolved device ownership. Further execution remains blocked.")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let intake = model.intake {
                    GroupBox("Selected app") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("App", selection: $model.candidateID) {
                                ForEach(intake.candidates) { Text($0.name).tag($0.id) }
                            }.onChange(of: model.candidateID) { model.selectCandidate() }
                            if model.candidate?.kind == .sourceTarget {
                                DisclosureGroup("Build settings") {
                                    Picker("Configuration", selection: $model.configuration) {
                                        ForEach(model.candidate?.configurations ?? [], id: \.self) { Text($0).tag($0) }
                                    }
                                }
                                AutomationSourcePreparationControls(model: model) {
                                    do { preparationReview = try model.reviewNativePreparation(); approveBuild = true }
                                    catch { model.message = "The app or destination changed. Review the selection before building." }
                                }
                            } else if model.isInstalledUI {
                                Picker("Simulator", selection: $model.simulatorID) {
                                    ForEach(model.simulators) { Text("\($0.name) · \($0.state)").tag($0.id) }
                                }
                            }
                            if model.isInstalledMacUI {
                                Text("Selected Mac app · current login session").font(.callout).foregroundStyle(.secondary)
                            }
                            if model.candidate?.kind == .sourceTarget {
                                Picker("What to test", selection: $model.workflowRoute) {
                                    Text("App workflow").tag("ui")
                                    Text("System action").tag("system")
                                    Text("Action on a new test record").tag("fresh")
                                    if model.preparationDestination == .physical { Text("Siri recognised-text submission").tag("siri") }
                                }.accessibilityLabel("What to test").onChange(of: model.workflowRoute) { model.workflowSelectionChanged() }
                            }
                            ForEach(intake.gaps, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10).disabled(model.busy)
                    }
                } else {
                    ContentUnavailableView("Choose an app to begin", systemImage: "app",
                        description: Text("Select an Xcode project, workspace, source folder or packaged app. Selection only inspects files."))
                }
                if model.isUIWorkflow {
                    GroupBox("UI workflow") {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("What should the app do?", text: $model.uiInstruction, axis: .vertical)
                            TextField("Visible label at the destination", text: $model.uiEndpoint)
                            if model.isMacUIReview {
                                Text("Mac drafts support navigation and visible checks. Text entry awaits qualification.").font(.callout).foregroundStyle(.secondary)
                                if !model.uiApprovedText.isEmpty {
                                    Button("Clear text input to review this Mac draft") { model.uiApprovedText = "" }
                                }
                            } else {
                                TextField("Approved text to enter (optional)", text: $model.uiApprovedText)
                            }
                            Picker("Property to check", selection: $model.uiObservationProperty) {
                                Text("Visible text").tag("text")
                                Text("Control value").tag("value")
                                Text("Checked state").tag("checked")
                                Text("Selected state").tag("selected")
                            }
                            if model.uiObservationProperty != "text" {
                                TextField("Element label for the check", text: $model.uiObservationLabel)
                            }
                            TextField(["checked", "selected"].contains(model.uiObservationProperty) ? "Expected value: true or false (optional)" : "Expected property value (optional)", text: $model.uiExpectedText)
                            Picker("Effects of this workflow", selection: $model.effectChoice) {
                                Text("Choose the workflow's effects").tag("")
                                Text("Observation and navigation").tag("navigation")
                                Text("Changes to test fixtures").tag("fixture")
                                Text("External changes").tag("external")
                            }.accessibilityLabel("Effects of this workflow")
                            Toggle("I confirm this workflow stays within these effects", isOn: $model.effectsConfirmed)
                            Toggle("Disposable test environment", isOn: $model.disposable)
                            if !model.isMacUIReview {
                                Toggle("Allow starting this simulator and installing the selected app", isOn: $model.installApproved)
                            }
                            Text(model.uiExpectedText.isEmpty ? "Navigation completion will be unassessed. Add a visible-state check to assess a requirement." : "The visible-state check runs separately after navigation.").font(.callout).foregroundStyle(.secondary)
                            if model.isMacUIReview {
                                Text("Mac execution is awaiting verification. You can review and save a workflow draft.").font(.callout).foregroundStyle(.secondary)
                                Button("Review Mac workflow…") {
                                    do { macWorkflowReview = try model.reviewMacWorkflow() }
                                    catch { model.message = "The app, Mac session or workflow inputs changed. Reselect the app and review again." }
                                }.disabled(!model.canReviewMacWorkflow)
                            } else {
                                Button("Run workflow…") { presentNativeConfirmation(.run) }.disabled(!model.canRun || model.pendingCommandStatus?.kind != nil)
                                Divider()
                                TextField("Alternative phrases, one per line (up to two)", text: $model.uiAlternatePhrases, axis: .vertical)
                                Text("Phrase trials keep the destination, inputs and business check fixed. Up to 20 attempts, 1,000 UI actions and 300 controller calls; at most one hour.").font(.callout).foregroundStyle(.secondary)
                                Button("Find failures…") {
                                    do { searchReview = try model.reviewNativeSearch(); approveSearch = true }
                                    catch { model.message = "The workflow or phrases changed. Review them before searching." }
                                }.disabled(!model.canFindFailures)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10).disabled(model.busy)
                    }
                }
                if model.isSiriWorkflow { AutomationSiriControls(model: model) { presentNativeConfirmation(.run) } }
                if let catalog = model.catalog, !model.isUIWorkflow, !model.isSiriWorkflow {
                    GroupBox("System actions") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("\(catalog.systemActions.count) compiled declarations · discovery is partial").foregroundStyle(.secondary)
                            Picker("Action", selection: $model.actionID) {
                                Text("Choose action").tag("")
                                ForEach(catalog.systemActions) { Text($0.title).tag($0.id) }
                            }.accessibilityLabel("Action").onChange(of: model.actionID) { model.selectAction() }
                            if let action = model.action {
                                if model.isFreshRecordWorkflow {
                                    freshRecordInputs
                                } else {
                                    ForEach(action.parameters, id: \.name) { parameter in
                                        if parameter.family == "entity" { entityInput(parameter) }
                                        else { typedInput(parameter) }
                                    }
                                }
                                Picker("Effects of this action", selection: $model.effectChoice) {
                                    Text("Choose the action's effects").tag("")
                                    Text("Observation and navigation").tag("navigation")
                                    Text("Changes to test fixtures").tag("fixture")
                                    Text("External changes").tag("external")
                                }.accessibilityLabel("Effects of this action")
                                Toggle("I confirm this action stays within these effects", isOn: $model.effectsConfirmed)
                                Text("This is your declaration of the action's behaviour. Intents cannot block an app's side effects after dispatch.").font(.callout).foregroundStyle(.secondary)
                                Toggle("Disposable test environment", isOn: $model.disposable)
                                if model.preparationDestination == .simulator {
                                    Toggle("Allow starting this simulator and installing the prepared app", isOn: $model.installApproved)
                                }
                                Text("Only the expected record states you choose are assessed. Invocation alone remains unassessed.").font(.callout).foregroundStyle(.secondary)
                                if model.isFreshRecordWorkflow && model.preparationDestination == .macOS {
                                    Text("Mac execution is awaiting verification. You can review and save a record workflow draft.").font(.callout).foregroundStyle(.secondary)
                                    Button("Review Mac record workflow…") {
                                        do { macWorkflowReview = try model.reviewPreparedMacFreshWorkflow() }
                                        catch { model.message = "The app, Mac session or record workflow changed. Review the selection and inputs again." }
                                    }.disabled(!model.canReviewPreparedMacFreshWorkflow)
                                } else {
                                    Button(model.isFreshRecordWorkflow ? "Run test record workflow…" : "Run action…") { presentNativeConfirmation(.run) }.disabled(!model.canRun || model.pendingCommandStatus?.kind != nil)
                                }
                            }
                            ForEach(catalog.gaps, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                            if model.prepared == nil { Text("Prepare an associated host to run this app's system actions.").font(.callout) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10).disabled(model.busy)
                    }
                }
                if let result = model.searchReport { searchResult(result, title: "Failure search") }
                if let result = model.reproductionReport { reproductionResult(result, title: "Reproduction") }
                if !model.savedReproductions.isEmpty {
                    GroupBox("Saved reproductions") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(model.savedReproductions.prefix(savedCaseLimit)), id: \.runID) { record in
                                Button("View reproduction · \(record.matchingFailures)/\(record.attempts.count) matching") { model.viewedReproduction = record }.disabled(model.busy)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                }
                if let viewed = model.viewedReproduction {
                    reproductionResult(viewed, title: "Saved reproduction outcomes")
                    Button("Close saved reproduction") { model.viewedReproduction = nil }
                }
                if !model.savedSearches.isEmpty {
                    GroupBox("Saved searches") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(model.savedSearches.prefix(savedCaseLimit)), id: \.id) { record in
                                HStack {
                                    Text(record.baseline.plan.execution.operation).lineLimit(2)
                                    Spacer()
                                    Button("View search") { model.viewedSearch = record }.disabled(model.busy)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                }
                if let viewed = model.viewedSearch {
                    searchResult(viewed.report, title: "Saved search outcomes")
                    Button("Close saved search") { model.viewedSearch = nil }
                }
                if let pending = model.pendingCommandStatus {
                    GroupBox("Execution request") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(pending.kind == .fixComparison ? "Review the selected builds below, then confirm Check fix to run the unchanged case 30 times per build." : pending.kind == .reproduction ? "Review the saved failure below, then confirm Reproduce failure to run its frozen case five times." : "Review the app, inputs and permitted effects above, then confirm Run.")
                            Text("Request \(pending.requestID.uuidString)").font(.caption).textSelection(.enabled)
                            Button("Dismiss request") { _ = try? model.cancelCommand(id: pending.requestID) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                }
                if let importMessage = model.evidenceImportMessage { Text(importMessage).font(.callout).foregroundStyle(.secondary) }
                if let progress = model.progress {
                    HStack { ProgressView().controlSize(.small); Text(progress); Spacer(); Button("Cancel") { model.cancel() } }
                }
                if let report = model.report {
                    GroupBox("Result") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(resultTitle(report)).font(.title3.weight(.semibold))
                            if let reason = report.result.policyDenial {
                                Text(reason.explanation).font(.callout)
                            }
                            Text("Subject dispatched: \(report.result.subjectDispatched ? "yes" : "no") · completed: \(report.result.subjectCompleted ? "yes" : "no")")
                            Text(report.resourcesReleased ? "Owned controllers released." : "Controller release is unresolved; the target remains quarantined.")
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                }
                if let presentation = model.canonicalPresentation, presentation.document.report == model.report {
                    GroupBox("Native evidence") { NativeAutomationEvidenceView(presentation: presentation).padding(10) }
                }
                if let directory = model.reportDirectory {
                    Button("Show this attempt's evidence") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                AppAutomationCapsuleView(model: model)
                if !model.savedCases.isEmpty {
                    GroupBox("Saved cases") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(model.savedCases.prefix(savedCaseLimit)), id: \.digest) { frozen in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(frozen.plan.execution.operation).font(.headline)
                                        Text("\(frozen.plan.app.bundleID) · version \(frozen.plan.revision)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("View saved case") { Task { await model.showSavedCase(frozen) } }.disabled(model.busy)
                                }
                            }
                            if model.savedCases.count > savedCaseLimit {
                                Button("Show more saved cases") { savedCaseLimit += 50 }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                }
                if let frozen = model.savedViewedCase {
                    GroupBox("Saved attempts") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(frozen.plan.app.bundleID + " · " + frozen.plan.execution.operation).font(.headline)
                            if model.savedAttemptLoading {
                                ProgressView("Loading saved attempts…")
                            } else if model.savedViewedAttempts.isEmpty {
                                Text("This saved draft has no execution result.").foregroundStyle(.secondary)
                            } else {
                                Picker("Attempt", selection: Binding(get: { model.savedAttemptSelection }, set: { id in
                                    Task { await model.selectSavedAttempt(id: id) }
                                })) {
                                    Text("Choose an attempt").tag("")
                                    ForEach(model.savedViewedAttempts, id: \.attemptID) { attempt in
                                        Text(attempt.attemptID + " · " + resultTitle(attempt)).tag(attempt.attemptID)
                                    }
                                }.disabled(model.busy)
                                if model.savedViewedReport == nil {
                                    Text("Choose the failure to inspect or reproduce. Attempt IDs do not indicate time order.").font(.callout).foregroundStyle(.secondary)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                }
                if let report = model.savedViewedReport {
                    GroupBox("Saved result") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(resultTitle(report)).font(.headline)
                            if let reason = report.result.policyDenial {
                                Text(reason.explanation).font(.callout)
                            }
                            if report.result.summary == .assertionFailed {
                                Button("Reproduce failure…") { presentNativeConfirmation(.reproduction) }.disabled(!model.canReproduceSavedFailure)
                                if model.isInstalledUI || model.isInstalledMacUI {
                                    Button("Choose fixed app…") { chooseFixedApp() }.disabled(!model.canSelectFix)
                                } else {
                                    Button("Build fixed source…") { model.prepare() }.disabled(!model.canPrepareSourceFix)
                                    Text("Edit the selected source, then build it here. The original prepared build and saved checks are retained.").font(.caption)
                                }
                                if let fixed = model.fixedAppName {
                                    Text("Fixed build: \(fixed)")
                                    Button("Check fix…") { presentNativeConfirmation(.comparison) }.disabled(!model.canCheckFix)
                                    if !model.isInstalledMacUI && !model.installApproved { Text("Allow installation above to compare the two exact builds.").font(.caption) }
                                }
                            }
                            Text("Subject dispatched: \(report.result.subjectDispatched ? "yes" : "no") · completed: \(report.result.subjectCompleted ? "yes" : "no")")
                            if let directory = model.savedViewedDirectory { Button("Show saved evidence") { NSWorkspace.shared.activateFileViewerSelecting([directory]) } }
                            if let presentation = model.canonicalSavedPresentation, presentation.document.report == report { NativeAutomationEvidenceView(presentation: presentation) }
                            Button("Close saved result") { model.clearSavedView() }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                }
                if let result = model.comparisonReport { comparisonResult(result, title: "Fix comparison") }
                if !model.savedComparisons.isEmpty {
                    GroupBox("Saved fix comparisons") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.savedComparisons.prefix(50), id: \.beforeRunID) { record in
                                Button("View comparison: \(record.beforeCounters.failed) → \(record.afterCounters.failed) failures") { model.viewedComparison = record }.disabled(model.busy)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                }
                if let viewed = model.viewedComparison {
                    comparisonResult(viewed, title: "Saved fix comparison")
                    Button("Close saved comparison") { model.viewedComparison = nil }
                }
                if let message = model.message { Text(message).textSelection(.enabled).foregroundStyle(.secondary) }
            }.padding(28).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity)
        }
        .task(id: model.simulatorInventorySelection) { await model.refreshTargets() }
        .task { await model.refreshSavedCases() }
        .sheet(item: $macWorkflowReview) { review in
            VStack(alignment: .leading, spacing: 14) {
                Text("Review Mac workflow").font(.title2)
                LabeledContent("App", value: review.plan.app.bundleID)
                LabeledContent("Selected copy", value: review.bundlePath)
                Text(review.kind == .freshRecord ? review.plan.setup.first?.operation ?? "" : review.plan.execution.operation).textSelection(.enabled)
                LabeledContent("Destination", value: (review.kind == .freshRecord ? review.plan.setup.first : review.plan.execution)?.uiProgram?.operations.first?.goal?.endpoint.value ?? "")
                if review.kind == .freshRecord {
                    Text("Create test records → query their real identities → run \(review.plan.execution.operation) → independently query the resulting states.").font(.callout)
                }
                Text(review.visibleCheck).font(.callout)
                LabeledContent("Permitted effects", value: review.approval.effects.map(\.rawValue).sorted().joined(separator: ", "))
                Text("This draft has no execution result. Saving it does not approve or run the app.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Save draft") {
                        Task {
                            do { try await model.saveMacWorkflowDraft(review); macWorkflowReview = nil }
                            catch {
                                model.message = "The workflow changed or could not be saved. Review it again."
                                macWorkflowReview = nil
                            }
                        }
                    }.disabled(model.busy)
                    Spacer()
                    Button("Done") { macWorkflowReview = nil }.keyboardShortcut(.cancelAction)
                }
            }.padding(24).frame(minWidth: 520, idealWidth: 600)
        }
        .onChange(of: model.configuration) { model.preparationSelectionChanged() }
        .onChange(of: model.simulatorID) { model.preparationSelectionChanged() }
        .onChange(of: model.physicalDeviceID) { model.preparationSelectionChanged() }
        .onChange(of: model.preparationDestination) { model.preparationSelectionChanged() }
        .onChange(of: model.effectChoice) { model.effectSelectionChanged() }
        .alert("Build the selected app?", isPresented: $approveBuild) {
            Button("Build private copy") {
                guard let review = preparationReview else { return }; preparationReview = nil
                do { try model.confirmNativePreparation(review) }
                catch { model.message = "The app, configuration or destination changed. Review the build again." }
            }
            Button("Cancel", role: .cancel) { preparationReview = nil }
        } message: { Text(preparationReview?.message ?? "Review the selected build again.") }
        .alert("Explore these approved phrases?", isPresented: $approveSearch) {
            Button("Find failures") {
                guard let review = searchReview else { return }; searchReview = nil
                Task { await model.findFailures(reviewed: review) }
            }
            Button("Cancel", role: .cancel) { searchReview = nil }
        } message: { Text(searchReview?.message ?? "Review the selected workflow and phrases again.") }
        .alert("Reproduce the saved failure?", isPresented: $approveReproduction) {
            Button("Run five attempts") { confirmNativeConfirmation() }
            Button("Cancel", role: .cancel) { cancelNativeConfirmation() }
        } message: { Text(nativeConfirmation?.message ?? "Review this request again.") }
        .alert("Compare both retained builds?", isPresented: $approveComparison) {
            Button("Run 30 attempts per build") { confirmNativeConfirmation() }
            Button("Cancel", role: .cancel) { cancelNativeConfirmation() }
        } message: { Text(nativeConfirmation?.message ?? "Review this request again.") }
        .alert("Run the selected workflow?", isPresented: $approveRun) {
            Button("Run approved workflow") { confirmNativeConfirmation() }
            Button("Cancel", role: .cancel) { cancelNativeConfirmation() }
        } message: { Text(nativeConfirmation?.message ?? "Review this request again.") }
    }
    private func presentNativeConfirmation(_ kind: AutomationNativeConfirmationKind) {
        guard !nativeConfirmationLoading else { return }
        nativeConfirmationLoading = true
        Task {
            defer { nativeConfirmationLoading = false }
            do {
                nativeConfirmation = try await model.prepareNativeConfirmation(kind)
                switch kind {
                case .run: approveRun = true
                case .reproduction: approveReproduction = true
                case .comparison: approveComparison = true
                }
            } catch { model.message = "The selected app, destination or saved result changed. Review it again before confirming." }
        }
    }
    private func confirmNativeConfirmation() {
        guard let review = nativeConfirmation else { return }
        nativeConfirmation = nil
        Task {
            do { try await model.confirmNativeRequest(review) }
            catch { model.message = "This request is no longer awaiting approval. Review the selected app and result again." }
        }
    }
    private func cancelNativeConfirmation() {
        if let review = nativeConfirmation { _ = try? model.cancelCommand(id: review.id) }
        nativeConfirmation = nil
    }

    private func reproductionResult(_ report: AutomationReproductionReport, title: String) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(report.matchingFailures) matching failures / \(report.attempts.count) recorded attempts")
                Text("\(report.assessedPasses) passes · \(report.otherFailures) other failures · \(report.unassessed) unassessed").font(.callout).foregroundStyle(.secondary)
                Text(report.complete ? "All five attempts finished and released their controllers." : "Reproduction is incomplete.")
                if let reason = report.stopReason { Text(reason).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
    }
    private func searchResult(_ report: AutomationFailureSearchReport, title: String) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(report.counters.failed) requirement failures · \(report.counters.assessed) assessed · \(report.counters.unassessed) unassessed")
                Text("\(report.attempts.count) recorded attempts · \(report.interruptions.count) interrupted")
                if let final = report.finalReproduction {
                    Text("Final reproduction: \(final.matchingFailures) matching failures / \(final.attempts.count) attempts")
                    Text("\(final.assessedPasses) passes · \(final.otherFailures) other failures · \(final.unassessed) unassessed").font(.callout).foregroundStyle(.secondary)
                }
                if let reason = report.stopReason { Text(reason).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
    }
    @ViewBuilder private var freshRecordInputs: some View {
        if let entity = model.freshEntity {
            if model.learnedSetupRecipe != nil {
                Toggle("Use the learned setup path", isOn: $model.useLearnedSetup)
                    .onChange(of: model.useLearnedSetup) { _, _ in model.workflowSelectionChanged() }
                Text("This path created independently checked fresh records in two runs. Review and approve the new plan before using it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Each attempt creates a new record in the app, runs this action on that record, then checks its state independently.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("How should the app create and save the record?", text: $model.uiInstruction, axis: .vertical)
            TextField("Visible destination after saving", text: $model.uiEndpoint)
            TextField("Save button label (optional)", text: $model.freshSaveControl)
                .onChange(of: model.freshSaveControl) { _, _ in model.workflowSelectionChanged() }
            Text("When supplied, Intents requires one tap on this button before finishing setup. The record query still checks that saving worked.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Test record name prefix", text: $model.freshNamePrefix)
            Text("Intents adds a unique suffix to this name for each attempt. The controller may enter only that approved name.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Record name", selection: $model.freshNameProperty) {
                Text("Choose name property").tag("")
                ForEach(entity.properties.keys.filter { entity.properties[$0] == "text" }.sorted(), id: \.self) { name in
                    Text(entity.propertyTitles[name] ?? name).tag(name)
                }
            }.accessibilityLabel("Record name")
            Toggle("Check another record with the same name stays unchanged", isOn: $model.freshProtectOtherRecord)
            if model.freshProtectOtherRecord {
                Picker("Distinguish records by", selection: $model.freshContextProperty) {
                    Text("Choose owner or list property").tag("")
                    ForEach(entity.properties.keys.filter { entity.properties[$0] == "text" && $0 != model.freshNameProperty }.sorted(), id: \.self) { name in
                        Text(entity.propertyTitles[name] ?? name).tag(name)
                    }
                }.accessibilityLabel("Distinguish records by")
                TextField("Owner or list of the record to act on", text: $model.freshSelectedContext)
                TextField("Owner or list of the record to keep unchanged", text: $model.freshProtectedContext)
                Text("Both records use the same test name. Intents queries each real record by its owner or list and checks both after the action.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("State to check", selection: $model.freshStateProperty) {
                Text("Choose state property").tag("")
                ForEach(entity.properties.keys.filter { entity.properties[$0] == "bool" }.sorted(), id: \.self) { name in
                    Text(entity.propertyTitles[name] ?? name).tag(name)
                }
            }.accessibilityLabel("State to check")
            Picker("State before the action", selection: $model.freshInitialState) {
                Text("Choose initial state").tag(""); Text("True").tag("true"); Text("False").tag("false")
            }.accessibilityLabel("State before the action")
            Picker("Expected state after the action", selection: $model.freshExpectedState) {
                Text("Choose expected state").tag(""); Text("True").tag("true"); Text("False").tag("false")
            }.accessibilityLabel("Expected state after the action")
        } else {
            Text("This workflow needs an action with one record input and readable name and Boolean state properties.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func typedInput(_ parameter: ApplicationSurfaceCatalog.SystemAction.Parameter) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            let binding = Binding(get: { model.inputs[parameter.name] ?? "" }, set: { model.inputs[parameter.name] = ["bool", "enum"].contains(parameter.family ?? "") && $0.isEmpty ? nil : $0 })
            if parameter.family == "date" {
                AppAutomationDateInput(name: parameter.name, rawInput: Binding(get: { model.inputs[parameter.name] }, set: { model.inputs[parameter.name] = $0 }))
            } else if parameter.family == "bool" {
                Picker(parameter.name, selection: binding) {
                    Text("Choose a value").tag("")
                    Text("True").tag("true"); Text("False").tag("false")
                }
            } else if parameter.family == "enum", let enumeration = model.catalog?.enumerations?.first(where: { $0.typeID == parameter.typeID }) {
                Picker(parameter.name, selection: binding) {
                    Text("Choose a value").tag("")
                    ForEach(enumeration.cases) { Text($0.title).tag($0.id) }
                }
            } else {
                TextField(parameter.name + (parameter.family == "calendarComponents" ? " (JSON with quoted components and optional calendar context)" : parameter.family == "duration" ? " (JSON with quoted seconds and attoseconds)" : parameter.family == "textArray" ? " (JSON list of text values)" : parameter.family == "boolArray" ? " (JSON list of true/false values)" : parameter.family == "integerArray" ? " (JSON list of whole numbers)" : parameter.family == "decimalArray" ? " (JSON list of quoted decimal values)" : parameter.family == "dateArray" ? " (JSON list of value/timeZone objects)" : parameter.family == "integer" ? " (whole number)" : parameter.family == "decimal" ? " (decimal number)" : ""), text: binding)
                    .disabled(parameter.family == nil)
            }
            if parameter.defaultValue != nil {
                Text("Uses the app's declared default until you enter a value.").font(.caption).foregroundStyle(.secondary)
            } else if parameter.optional {
                Text("Optional; omitted until you enter a value.").font(.caption).foregroundStyle(.secondary)
            }
            if model.inputs[parameter.name] != nil {
                Button(parameter.defaultValue != nil ? "Use declared default" : "Omit input") { model.inputs[parameter.name] = nil }
                    .disabled(!parameter.optional && parameter.defaultValue == nil)
                if let catalog = model.catalog, (try? AutomationCodecRegistry.input(model.inputs[parameter.name] ?? "", parameter: parameter, catalog: catalog)) == nil {
                    Text("Enter a valid value for this input.").font(.caption).foregroundStyle(.red)
                }
            }
            if parameter.family == nil { Text("This input type is not supported yet.").font(.caption).foregroundStyle(.secondary) }
        }.disabled(model.busy)
    }

    @ViewBuilder private func entityInput(_ parameter: ApplicationSurfaceCatalog.SystemAction.Parameter) -> some View {
        if let entity = model.entityDefinition(parameter) {
            VStack(alignment: .leading, spacing: 8) {
                Text(entity.title + (parameter.optional ? " (optional)" : "")).font(.headline)
                HStack {
                    TextField("Search existing records", text: Binding(get: { model.entityQueryTexts[parameter.name] ?? "" }, set: {
                        model.entityQueryTexts[parameter.name] = $0; model.entityQueryChanged(parameter.name)
                    })).disabled(model.busy)
                    Button("Find records") { Task { await model.findEntities(parameter) } }.disabled(!model.canFindEntities(parameter))
                }
                let choices = model.entityChoices[parameter.name] ?? []
                let labels = choices.map { AutomationNativeEntitySelection.label($0, entity: entity) }
                let unique = choices.filter { choice in labels.filter { $0 == AutomationNativeEntitySelection.label(choice, entity: entity) }.count == 1 }
                if !choices.isEmpty {
                    Picker("Actual record", selection: Binding(get: { model.selectedEntityIDs[parameter.name] ?? "" }, set: { model.selectedEntityIDs[parameter.name] = $0; model.protectedEntityIDs[parameter.name] = nil })) {
                        Text("Choose a returned record").tag("")
                        ForEach(unique.prefix(100)) { choice in
                            let label = AutomationNativeEntitySelection.label(choice, entity: entity)
                            Text(label).lineLimit(2).help(label).tag(choice.id)
                        }
                    }.disabled(model.busy)
                    Text("\(choices.count) records returned by this query; the selected identity is resolved again before the action.").font(.caption).foregroundStyle(.secondary)
                    if unique.count < choices.count { Text("Some records share all displayed properties. Refine the search before choosing them.").font(.caption) }
                    if unique.count > 100 { Text("Showing the first 100 distinct records. Refine the search for others.").font(.caption) }
                }
                if model.selectedEntity(parameter.name) != nil {
                    Text("Choose up to two other records to keep unchanged.").font(.caption)
                    ForEach(unique.filter { $0.id != model.selectedEntityIDs[parameter.name] }.prefix(100)) { other in
                        let selected = model.protectedEntityIDs[parameter.name] ?? []
                        Toggle("Keep " + AutomationNativeEntitySelection.label(other, entity: entity) + " unchanged", isOn: Binding(get: {
                            model.protectedEntityIDs[parameter.name]?.contains(other.id) == true
                        }, set: { keep in
                            if keep { model.protectedEntityIDs[parameter.name, default: []].insert(other.id) }
                            else { model.protectedEntityIDs[parameter.name]?.remove(other.id) }
                        })).disabled(model.busy || (selected.count >= 2 && !selected.contains(other.id)))
                    }
                    ForEach(entity.properties.keys.filter { entity.properties[$0] == "bool" }.sorted(), id: \.self) { property in
                        Picker("Expected " + (entity.propertyTitles[property] ?? property), selection: Binding(get: { model.entityExpectedBooleans[parameter.name + "." + property] ?? "" }, set: { model.entityExpectedBooleans[parameter.name + "." + property] = $0 })) {
                            Text("No business check").tag(""); Text("Yes").tag("true"); Text("No").tag("false")
                        }.disabled(model.busy)
                    }
                }
            }
        } else { Text("This record input has no qualified query declaration.").foregroundStyle(.secondary) }
    }
    private func comparisonResult(_ report: AutomationFixComparisonReport, title: String) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                Text(report.complete ? "Both populations completed" : "Comparison incomplete").font(.headline)
                Text("Before: \(report.beforeCounters.failed) failures · \(report.beforeCounters.assessed) assessed · \(report.before.count)/\(report.requestedAttemptsPerBuild) attempts")
                Text("After: \(report.afterCounters.failed) failures · \(report.afterCounters.assessed) assessed · \(report.after.count)/\(report.requestedAttemptsPerBuild) attempts")
                Text("Unassessed: before \(report.beforeCounters.unassessed), after \(report.afterCounters.unassessed)")
                Text("Frozen checks retained. Environment qualification remains incomplete.").font(.caption).foregroundStyle(.secondary)
                if let reason = report.stopReason { Text(reason).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
    }
    private func chooseFixedApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Choose fixed app"
        panel.message = "Choose a separately built simulator app with the same bundle identity. Retain the original selected bundle for fresh before-and-after runs."
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }; model.selectFixedBundle(url)
        }
        if let window = NSApplication.shared.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Choose app"
        panel.message = "Choose an app, Xcode project, workspace or source folder. Selection only inspects files."
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            model.select(url)
        }
        if let window = NSApplication.shared.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
    private func resultTitle(_ report: AutomationAttemptReport) -> String {
        switch report.result.summary {
        case .executedUnassessed: "Executed · unassessed"
        case .passed: "Passed the approved requirements"
        case .assertionFailed: "Requirement failed"
        case .cancelled: "Cancelled"
        case .timedOut: "Timed out"
        default: "Needs review · " + report.result.summary.rawValue
        }
    }
}
