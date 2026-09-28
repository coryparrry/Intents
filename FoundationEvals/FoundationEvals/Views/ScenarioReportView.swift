import AppKit
import SwiftUI

struct ScenarioReportView: View {
    @Bindable var coordinator: ScenarioCoordinator
    @Bindable var store: EvaluationStore
    var onSetup: () -> Void = {}
    @State private var showsHistoricalRun = false
    @State private var currentQualification: IntentEvidenceCaseDecision?
    @State private var qualificationError: String?
    @State private var baselineAssessmentOverlay: ScenarioAssessmentSelectionRecord?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DisclosureGroup("What do the results mean?") {
                    IntentLabHelp("Passed: required checks matched. Failed: a required check did not match. Needs review: captured evidence needs a separate assessment. Not observed: the run did not capture enough evidence. Not applicable: this part was skipped. Each part reports its own result; the overall result depends on the parts marked Required.")
                        .padding(.top, 6)
                }
                if !coordinator.executionRecords.isEmpty {
                    executionPicker
                }
                if coordinator.isRunning {
                    runningState
                } else if let plan = coordinator.selectedExecutionPlan,
                          let record = coordinator.selectedExecutionRecord,
                          !showsHistoricalRun {
                    coordinatedReport(plan: plan, record: record)
                } else if let run = coordinator.selectedRun {
                    if !coordinator.runs.isEmpty { runPicker }
                    report(run)
                } else {
                    emptyState
                }
                if !coordinator.runs.isEmpty && !coordinator.executionRecords.isEmpty {
                    Toggle("Inspect an earlier individual run", isOn: $showsHistoricalRun)
                        .font(.caption)
                    if showsHistoricalRun, coordinator.selectedRun != nil { runPicker }
                }
            }
            .workspacePage()
        }
        .task(id: coordinator.selectedExecutionID) {
            await reloadAssessmentDecision()
        }
    }

    private var executionPicker: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Coordinated run").font(.headline)
                Text("Every planned route and attempt stays in this result")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Saved coordinated run", selection: $coordinator.selectedExecutionID) {
                ForEach(coordinator.executionRecords) { record in
                    Text(record.completedAt.formatted(date: .abbreviated, time: .shortened))
                        .tag(UUID?.some(record.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 205)
        }
    }

    private func coordinatedReport(plan: ScenarioExecutionPlan, record: ScenarioExecutionRecord) -> some View {
        let definition = coordinator.definitions.first {
            $0.id == plan.definitionID && $0.version == plan.definitionVersion
                && $0.definitionDigest == plan.definitionDigest
        }
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(definition?.name ?? "Developer check").font(.title3.weight(.semibold))
                    Text("Frozen requirement · \(record.completedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ScenarioOutcomeBadge(outcome: record.aggregateOutcome)
            }
            Text("Planned \(record.plannedCount) · Executed \(record.executedCount) · Observed \(record.observedCount) · Scored \(record.scoredCount) · Passing \(record.passingCount)")
                .font(.callout.weight(.medium))
                .accessibilityIdentifier("Coordinated evidence counts")
            Text("Checked app build: \(plan.appProductDigest)")
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if let firstProblem = record.records.first(where: {
                $0.coordinate.required && ($0.state != .completed || $0.laneResult?.outcome != .passed)
            }) {
                Text("Inspect: \(firstProblem.coordinate.lane.title), attempt \(firstProblem.coordinate.repetition). \(firstProblem.detail ?? firstProblem.laneResult?.diagnostic ?? "Review its captured observation and artifact.")")
                    .font(.callout)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .workspaceInset(radius: 9)
            }
            ForEach(ScenarioLane.allCases) { lane in
                let planned = plan.coordinates.filter { $0.lane == lane }
                if !planned.isEmpty {
                    DisclosureGroup("\(lane.title) · \(planned.count) planned") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(planned) { coordinate in
                                coordinatedAttempt(coordinate, record: record, definition: definition)
                            }
                        }
                        .padding(.top, 8)
                    }
                    .padding(12)
                    .workspaceSurface(radius: 10)
                }
            }
            if !record.isComplete {
                Text("Incomplete coordinates remain visible and cannot qualify as a full passing run.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let decision = currentQualification {
                DisclosureGroup("Release qualification") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(decision.incompleteEvidence.isEmpty && decision.requiredFailures.isEmpty
                             ? "Qualified against the frozen requirement and evidence policy."
                             : "The frozen requirement is not qualified.")
                            .font(.caption.weight(.medium))
                        ForEach(decision.incompleteEvidence, id: \.self) { issue in
                            Label(issue, systemImage: "questionmark.circle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        ForEach(decision.requiredFailures, id: \.self) { failure in
                            Label(failure, systemImage: "xmark.circle")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                    .padding(.top, 8)
                }
            }
            if let qualificationError {
                Label("Saved evidence needs review: \(qualificationError)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let comparison = comparison(plan: plan, record: record) {
                DisclosureGroup("Compared with retained baseline") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(comparison.summary).font(.callout)
                        Text(comparison.isDirectlyComparable
                             ? "Same frozen requirements and qualified evidence"
                             : "This result cannot establish whether the fix helped")
                            .font(.caption.weight(.medium))
                        ForEach(comparison.qualificationIssues ?? [], id: \.self) { issue in
                            Label(issue, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding(.top, 8)
                }
            }
            HStack {
                Button("Run again with these requirements", systemImage: "arrow.clockwise") {
                    Task { await coordinator.rerunSelectedExecution() }
                }
                .disabled(coordinator.isRunning || definition == nil)
                Button("Export evidence bundle…", systemImage: "square.and.arrow.up") {
                    exportEvidence(recordID: record.id)
                }
                .disabled(coordinator.isRunning || definition == nil)
            }
        }
    }

    private func coordinatedAttempt(
        _ coordinate: ScenarioPlannedCoordinate, record: ScenarioExecutionRecord,
        definition: ScenarioDefinition?
    ) -> some View {
        let item = record.records.first { $0.id == coordinate.id }
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Attempt \(coordinate.repetition)").font(.callout.weight(.medium))
                Text(coordinate.required ? "Required" : "Optional")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(item?.state.rawValue ?? "notRun")
                    .font(.caption).foregroundStyle(.secondary)
                if let outcome = item?.laneResult?.outcome {
                    ScenarioOutcomeBadge(outcome: outcome)
                }
            }
            if let detail = item?.detail { Text(detail).font(.caption) }
            if let feature = item?.featureChild {
                LabeledContent("Captured feature output", value: feature.response.isEmpty ? "Absent" : feature.response)
                    .font(.caption)
                if let failure = feature.errorMessage { Text(failure).font(.caption).foregroundStyle(.orange) }
            }
            if let result = item?.laneResult {
                ForEach(result.observations.keys.sorted(), id: \.self) { key in
                    LabeledContent(key, value: display(result.observations[key])).font(.caption)
                    if let before = result.beforeObservations?[key] {
                        Text("Before: \(display(before))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ForEach(result.assertionResults) { assertion in
                    Label(assertion.message, systemImage: assertion.passed ? "checkmark.circle" : "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(assertion.passed ? .green : .red)
                }
                if let child = item?.evidenceRunID.flatMap({ id in coordinator.runs.first { $0.id == id } }) {
                    ForEach(result.artifacts) { artifact in
                        Link(destination: coordinator.artifactURL(run: child, artifact: artifact)) {
                            Label(artifact.filename, systemImage: artifactSymbol(artifact.kind))
                        }
                        .font(.caption)
                    }
                }
            }
            if let definition, let laneResultID = item?.evidenceLaneResultID {
                ForEach(definition.assertions.filter {
                    $0.kind == .semanticRubric && $0.applies(to: coordinate.lane)
                }) { assertion in
                    ScenarioSavedAssessmentControls(
                        coordinator: coordinator, store: store,
                        coordinateID: coordinate.id, laneResultID: laneResultID,
                        assertionID: assertion.id,
                        executionID: record.id, onSelectionChanged: reloadAssessmentDecision
                    )
                }
            }
        }
        .padding(10)
        .workspaceInset(radius: 8)
    }

    private func reloadAssessmentDecision() async {
        let selectedID = coordinator.selectedExecutionID
        currentQualification = nil
        qualificationError = nil
        baselineAssessmentOverlay = nil
        guard let selectedID else { return }
        await coordinator.reloadSelectedAssessmentOverlay(expectedExecutionID: selectedID)
        if let policy = coordinator.selectedExecutionPlan?.comparisonPolicy {
            baselineAssessmentOverlay = try? await coordinator.assessmentOverlay(for: policy.baselineRunID)
        }
        do {
            currentQualification = try await coordinator.qualificationForSelectedExecution()
        } catch {
            qualificationError = error.localizedDescription
        }
        if coordinator.selectedExecutionID != selectedID {
            currentQualification = nil
            qualificationError = nil
            baselineAssessmentOverlay = nil
        }
    }

    private func comparison(plan: ScenarioExecutionPlan,
                            record: ScenarioExecutionRecord) -> ScenarioComparisonReport? {
        guard let policy = plan.comparisonPolicy,
              let baselinePlan = coordinator.executionPlans.first(where: { $0.id == policy.baselineRunID }),
              let baselineRecord = coordinator.executionRecords.first(where: { $0.id == policy.baselineRunID }) else {
            return nil
        }
        let baselineChildIDs = Set(baselineRecord.records.filter { $0.coordinate.lane != .appFeature }
            .compactMap { $0.evidenceRunID })
        let candidateChildIDs = Set(record.records.filter { $0.coordinate.lane != .appFeature }
            .compactMap { $0.evidenceRunID })
        let baselineDefinition = coordinator.definitions.first {
            $0.id == baselinePlan.definitionID && $0.version == baselinePlan.definitionVersion
                && $0.definitionDigest == baselinePlan.definitionDigest
        }
        let candidateDefinition = coordinator.definitions.first {
            $0.id == plan.definitionID && $0.version == plan.definitionVersion
                && $0.definitionDigest == plan.definitionDigest
        }
        return ScenarioExecutionComparison.compare(
            baseline: .init(plan: baselinePlan, record: baselineRecord,
                            runs: coordinator.runs.filter { baselineChildIDs.contains($0.id) },
                            selectedAssessment: baselineAssessmentOverlay,
                            definition: baselineDefinition),
            candidate: .init(plan: plan, record: record,
                             runs: coordinator.runs.filter { candidateChildIDs.contains($0.id) },
                             selectedAssessment: coordinator.selectedAssessmentOverlay,
                             definition: candidateDefinition),
            policy: policy
        )
    }

    private func exportEvidence(recordID: UUID) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "IntentLab-\(recordID.uuidString.prefix(8)).intentlabrun"
        panel.canCreateDirectories = true
        panel.message = "Save the immutable evidence bundle for offline checking."
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                guard coordinator.selectedExecutionID == recordID else {
                    coordinator.notice = "Select the same coordinated run before exporting its evidence."
                    return
                }
                let url = destination.pathExtension == "intentlabrun"
                    ? destination : destination.appendingPathExtension("intentlabrun")
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    try await coordinator.exportSelectedExecution(to: url)
                    coordinator.notice = "Evidence bundle saved to \(url.lastPathComponent)."
                } catch {
                    coordinator.notice = error.localizedDescription
                }
            }
            .workspacePage()
        }
    }

    private var runPicker: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Test results").font(.headline)
                Text("Saved observations stay unchanged when you review a run")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Saved run", selection: $coordinator.selectedRunID) {
                Text("No run").tag(UUID?.none)
                ForEach(coordinator.runs) { run in
                    Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .tag(UUID?.some(run.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 190)
        }
    }

    private var runningState: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Running your test")
                .font(.headline)
            Text("Xcode is preparing and running this test on the selected device. Keep it available and respond to any permission prompts. Logs and captured results are saved with this attempt.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 300)
            Button("Stop test", role: .destructive) {
                Task { await coordinator.cancel() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .workspaceSurface()
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: 16) {
            WorkspaceIcon(symbol: "intent-lab", size: 32)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 8) {
                Text("No results yet")
                    .font(.headline)
                Text("Connect your app and run a test to see what passed and what needs attention.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("App evaluation reuses a saved evaluation. App action tests the action directly. Siri tests the request text on your iPhone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Connect app", action: onSetup)
                    .padding(.top, 4)

            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(22)
        .workspaceSurface()
    }

    private func report(_ run: ScenarioRun) -> some View {
        let frozenDefinition = coordinator.definition(for: run)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(frozenDefinition?.name ?? "Scenario v\(run.scenarioVersion)").font(.title3.weight(.semibold))
                    Text(run.startedAt.formatted(date: .abbreviated, time: .standard))
                        .font(.caption).foregroundStyle(.secondary)
                    if let definition = frozenDefinition,
                       definition.schemaVersion == ScenarioDefinition.reusableSchemaVersion {
                        Text("\(definition.purpose == .exploratory ? "Exploratory" : "Release requirement") · \(definition.checkMode == .basic ? "Basic" : "Behaviour")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                ScenarioOutcomeBadge(outcome: run.outcome)
            }

            Text(ScenarioDiagnosticClassifier.message(for: run.laneResults))
                .font(.callout)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .workspaceInset(radius: 9)

            ForEach(ScenarioLane.allCases) { lane in
                laneSection(lane, run: run, definition: frozenDefinition)
            }

            environmentSection(run)
            comparisonSection(run)
            releaseSection(run)
        }
    }

    private func laneDisplayName(_ lane: ScenarioLane) -> String {
        switch lane {
        case .appFeature: "App evaluation"
        case .intentIntegration: "App action"
        case .siri: "Siri"
        }
    }

    private func laneSection(_ lane: ScenarioLane, run: ScenarioRun, definition: ScenarioDefinition?) -> some View {
        let results = run.laneResults.filter { $0.lane == lane }
        let passed = results.count { $0.outcome == .passed }
        return DisclosureGroup {
            if results.isEmpty {
                Text(
                    definition?.coverage[lane] == .notApplicable
                        ? "This lane is not applicable to the frozen scenario."
                        : "No observation was imported for this lane."
                )
                .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 6)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(results) { result in
                        attemptCard(result, run: run, definition: definition)
                    }
                }
                .padding(.top, 8)
            }
        } label: {
            HStack {
                Label(laneDisplayName(lane), systemImage: laneSymbol(lane))
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(results.isEmpty ? (definition?.coverage[lane] == .notApplicable ? "Not included" : "Not observed") : "\(passed) / \(results.count) passed")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .workspaceSurface(radius: 10)
    }

    private func attemptCard(_ result: ScenarioLaneResult, run: ScenarioRun, definition: ScenarioDefinition?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Attempt \(result.attempt)").font(.caption.weight(.semibold))
                Text(result.executionStatus.rawValue).font(.caption).foregroundStyle(.secondary)
                Spacer()
                ScenarioOutcomeBadge(outcome: result.outcome)
            }
            if let diagnostic = result.diagnostic {
                Text(diagnostic).font(.caption)
            }
            if result.lane == .intentIntegration,
               result.outcome == .passed,
               definition?.schemaVersion == ScenarioDefinition.reusableSchemaVersion,
               definition?.checkMode == .basic {
                Text(definition?.requiredClaims?.contains(.returnedValueChecked) == true
                    ? "Returned values matched. Application state was not checked."
                    : "Execution passed. Application state was not checked.")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if let proposed = result.proposedCause {
                Label("Hypothesis: \(proposed)", systemImage: "lightbulb")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !result.observations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(result.observations.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: display(result.observations[key]))
                            .font(.caption)
                        if let source = result.observationSources?[key] {
                            Text("Source: \(source)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            ForEach(result.assertionResults) { assertion in
                Label(assertion.message, systemImage: assertion.passed ? "checkmark.circle" : "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(assertion.passed ? .green : .red)
            }
            if !result.artifacts.isEmpty {
                HStack(spacing: 10) {
                    ForEach(result.artifacts) { artifact in
                        Link(destination: coordinator.artifactURL(run: run, artifact: artifact)) {
                            Label(artifact.filename, systemImage: artifactSymbol(artifact.kind))
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .padding(10)
        .workspaceInset(radius: 8)
    }

    private func environmentSection(_ run: ScenarioRun) -> some View {
        DisclosureGroup("Measured environment") {
            VStack(alignment: .leading, spacing: 5) {
                LabeledContent("Xcode", value: run.environment.xcodeVersion)
                LabeledContent("SDK", value: run.environment.sdkVersion)
                LabeledContent("Device", value: run.environment.deviceModel)
                LabeledContent("OS", value: run.environment.operatingSystem)
                LabeledContent("Language / region", value: "\(run.environment.languageCode) / \(run.environment.regionCode)")
                LabeledContent("Siri configuration", value: run.environment.siriConfiguration ?? "Unknown")
                Text("Matching OS versions do not establish a pinned Siri model or perfect reproducibility.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.top, 8)
        }
    }

    @ViewBuilder private func comparisonSection(_ run: ScenarioRun) -> some View {
        if let comparison = coordinator.comparison(for: run) {
            DisclosureGroup("Previous compatible run") {
                VStack(alignment: .leading, spacing: 7) {
                    Text(comparison.summary).font(.caption)
                    ForEach(comparison.dimensions.filter { !$0.compatible }) { dimension in
                        Text("\(dimension.name): \(dimension.baseline) → \(dimension.candidate)")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private func releaseSection(_ run: ScenarioRun) -> some View {
        let report = coordinator.releaseReport(for: run)
        return DisclosureGroup("Release requirement") {
            VStack(alignment: .leading, spacing: 6) {
                Text(report.summary).font(.caption)
                ForEach(report.failures, id: \.self) {
                    Label($0, systemImage: "xmark.circle").font(.caption).foregroundStyle(.red)
                }
            }
            .padding(.top, 8)
        }
    }

    private func display(_ value: ScenarioValue?) -> String {
        guard let value else { return "Missing" }
        return switch value {
        case .null: "null"
        case .string(let value): value
        case .boolean(let value): String(value)
        case .integer(let value): String(value)
        case .number(let value): value.formatted()
        case .date(let value): value.resolvedInstant.formatted(date: .abbreviated, time: .standard)
        case .enumeration(let value): value.caseIdentifier
        case .entity(let value): value.identifier
        case .array(let values): "\(values.count) values"
        }
    }

    private func laneSymbol(_ lane: ScenarioLane) -> String {
        switch lane {
        case .appFeature: "cpu"
        case .intentIntegration: "app.badge.checkmark"
        case .siri: "waveform"
        }
    }

    private func artifactSymbol(_ kind: ScenarioArtifactKind) -> String {
        switch kind {
        case .evidenceJSON: "curlybraces"
        case .screenshot: "photo"
        case .buildLog, .testLog: "doc.text"
        case .resultBundle: "shippingbox"
        }
    }
}

/// Saved judgment is a separate action from running the app. The connection
/// disclosure is approved for this exact endpoint and evidence transfer.
private struct ScenarioSavedAssessmentControls: View {
    @Bindable var coordinator: ScenarioCoordinator
    @Bindable var store: EvaluationStore
    let coordinateID: UUID
    let laneResultID: UUID
    let assertionID: UUID
    let executionID: UUID
    let onSelectionChanged: () async -> Void

    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsPage") private var settingsPage = "mcp"
    @State private var connectionID: UUID?
    @State private var approvedDigest: String?
    @State private var history = ScenarioAssessmentHistory()
    @State private var isWorking = false

    private var connection: EvaluationJudgeConnection? {
        store.judgeConnections.first { $0.id == connectionID }
    }

    var body: some View {
        DisclosureGroup("Assess saved response") {
            VStack(alignment: .leading, spacing: 8) {
                Text("The app action will not run again. The judge reads this saved response and the expected outcome.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Independent judge", selection: $connectionID) {
                    Text("Choose a connection").tag(UUID?.none)
                    ForEach(store.judgeConnections) { judge in
                        Text(judge.name).tag(UUID?.some(judge.id))
                    }
                }
                if let connection {
                    Text("Evidence disclosure: the saved response, request, reference, and rubric will be sent to \(connection.name) at \(connection.baseURL) using model \(connection.modelID).")
                        .font(.caption)
                    if approvedDigest != connection.disclosureDigest {
                        Button("Approve this evidence transfer") {
                            approvedDigest = connection.disclosureDigest
                        }
                    } else {
                        Label("Approved for this connection", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.green)
                    }
                } else {
                    Button("Manage judge connections…") {
                        settingsPage = "judges"
                        openSettings()
                    }
                }
                Button("Assess saved response", systemImage: "checkmark.bubble") {
                    guard let connection else { return }
                    isWorking = true
                    Task {
                        var configuration = EvaluationJudgeConfiguration()
                        configuration.mode = .connection
                        configuration.connectionID = connection.id
                        configuration.includeReferenceAttachments = true
                        configuration.externalEvidenceApprovedAt = Date()
                        configuration.approvedConnectionID = connection.id
                        configuration.approvedIncludeReferenceAttachments = true
                        configuration.approvedConnectionDigest = connection.disclosureDigest
                        _ = await coordinator.reassessSelectedCoordinate(
                            coordinateID: coordinateID, assertionID: assertionID,
                            judgeConfiguration: configuration
                        )
                        await refresh()
                        await onSelectionChanged()
                        isWorking = false
                    }
                }
                .disabled(isWorking || connection == nil || approvedDigest != connection?.disclosureDigest)
                if isWorking { ProgressView().controlSize(.small) }
                if !history.assessments.isEmpty {
                    Picker("Selected saved assessment", selection: Binding(
                        get: { history.selected(for: laneResultID, assertionID: assertionID)?.id },
                        set: { id in
                            guard let id else { return }
                            Task {
                                await coordinator.selectAssessment(id, coordinateID: coordinateID,
                                                                   assertionID: assertionID)
                                await refresh()
                                await onSelectionChanged()
                            }
                        }
                    )) {
                        Text("No selection").tag(UUID?.none)
                        ForEach(history.assessments) { assessment in
                            Text("\(assessment.assessment.judge.displayName) · \(assessment.sample?.status.rawValue ?? "unscored")")
                                .tag(UUID?.some(assessment.id))
                        }
                    }
                    Text("Earlier assessments stay in history when you select or retry another one.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Retry saving assessment selection") {
                        Task {
                            await coordinator.retryAssessmentSelectionSave()
                            await onSelectionChanged()
                        }
                    }
                }
            }
            .padding(.top, 8)
        }
        .task(id: executionID) { await refresh() }
    }

    private func refresh() async {
        guard coordinator.selectedExecutionID == executionID else { return }
        do { history = try await coordinator.assessmentHistory(coordinateID: coordinateID) }
        catch { coordinator.notice = error.localizedDescription }
    }
}
