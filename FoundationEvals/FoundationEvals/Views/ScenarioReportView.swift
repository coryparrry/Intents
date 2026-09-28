import SwiftUI

struct ScenarioReportView: View {
    @Bindable var coordinator: ScenarioCoordinator
    var onSetup: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DisclosureGroup("What do the results mean?") {
                    IntentLabHelp("Passed: required checks matched. Failed: a required check did not match. Needs review: captured evidence needs a separate assessment. Not observed: the run did not capture enough evidence. Not applicable: this part was skipped. Each part reports its own result; the overall result depends on the parts marked Required.")
                        .padding(.top, 6)
                }
                if !coordinator.runs.isEmpty {
                    runPicker
                }
                if coordinator.isRunning {
                    runningState
                } else if let run = coordinator.selectedRun {
                    report(run)
                } else {
                    emptyState
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
