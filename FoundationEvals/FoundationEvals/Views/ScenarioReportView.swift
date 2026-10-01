import SwiftUI

struct ScenarioReportView: View {
    @Bindable var coordinator: ScenarioCoordinator
    var onSetup: () -> Void = {}
    var onCreateTest: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !coordinator.runs.isEmpty { runPicker }
                if coordinator.isRunning {
                    runningState
                } else if let run = coordinator.selectedRun {
                    report(run).id(run.id)
                } else {
                    emptyState
                }
                resultsHelp
            }
            .frame(maxWidth: 960, alignment: .leading)
            .workspacePage()
        }
    }

    private var runPicker: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text("Test results").font(.title3.weight(.semibold))
                Spacer()
                savedRunPicker
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Test results").font(.title3.weight(.semibold))
                savedRunPicker
            }
        }
    }

    private var savedRunPicker: some View {
        Picker("Saved run", selection: $coordinator.selectedRunID) {
            Text("No run").tag(UUID?.none)
            ForEach(coordinator.runs) { run in
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .tag(UUID?.some(run.id))
            }
        }
        .frame(maxWidth: 260)
    }

    private var runningState: some View {
        HStack(alignment: .top, spacing: 16) {
            ProgressView().controlSize(.large)
            VStack(alignment: .leading, spacing: 8) {
                Text("Running your test").font(.headline)
                Text("Xcode is running this test on the selected device. Keep it available and respond to any permission prompts.")
                    .foregroundStyle(.secondary)
                Button("Stop test", role: .destructive) { Task { await coordinator.cancel() } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .workspaceSurface()
    }

    private var emptyState: some View {
        IntentLabCard("No results yet", subtitle: "Run a test to see what worked and what needs attention.") {
            HStack(spacing: 12) {
                Button("Connect app", action: onSetup)
                Button("Create test", action: onCreateTest)
            }
        }
    }

    private func report(_ run: ScenarioRun) -> some View {
        let definition = coordinator.definition(for: run)
        let presentation = ScenarioReportPresentation(run: run, definition: definition)
        return VStack(alignment: .leading, spacing: 22) {
            outcomeSummary(run, definition: definition, presentation: presentation)
            VStack(alignment: .leading, spacing: 12) {
                Text("What was checked").font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(presentation.includedLanes) { lane in
                    laneSection(lane, run: run, definition: definition, presentation: presentation)
                }
                if !presentation.omittedLanes.isEmpty {
                    Text("Not included: \(presentation.omittedLanes.map { ScenarioReportPresentation.title(for: $0) }.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Run details") {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Saved observations stay unchanged when you review a run.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Started", value: run.startedAt.formatted(date: .abbreviated, time: .standard))
                    LabeledContent("Finished", value: run.completedAt.formatted(date: .abbreviated, time: .standard))
                    if let definition {
                        LabeledContent("Test version", value: "v\(definition.version)")
                        if let purpose = definition.purpose {
                            LabeledContent("Purpose", value: purpose == .releaseRequirement ? "Release requirement" : "Exploratory test")
                        }
                        if let mode = definition.checkMode {
                            LabeledContent("Verification", value: mode == .basic ? "Execution and returned values" : "Observed app behavior")
                        }
                    }
                    environmentSection(run)
                    comparisonSection(run)
                    releaseSection(run)
                    DisclosureGroup("Troubleshooting") {
                        Text(ScenarioDiagnosticClassifier.message(for: run.laneResults))
                            .font(.callout).padding(.top, 6)
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    private func outcomeSummary(_ run: ScenarioRun, definition: ScenarioDefinition?, presentation: ScenarioReportPresentation) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(definition?.name ?? "Test v\(run.scenarioVersion)")
                        .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    Text(presentation.headline)
                        .font(.title2.weight(.semibold))
                }
                Spacer(minLength: 8)
                ScenarioOutcomeBadge(outcome: run.outcome)
            }
            if let definition {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    summaryField("Request", value: definition.goal.requestText)
                    summaryField("Expected result", value: definition.goal.expectedBehavior)
                }
            }
            Label(presentation.nextStep, systemImage: "arrow.right.circle")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workspaceSurface()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("Intent Lab result summary")
    }

    private func summaryField(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(value.isEmpty ? "Not specified" : value).font(.callout).textSelection(.enabled)
        }
    }

    private func laneSection(_ lane: ScenarioLane, run: ScenarioRun, definition: ScenarioDefinition?, presentation: ScenarioReportPresentation) -> some View {
        let results = run.laneResults.filter { $0.lane == lane }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label(ScenarioReportPresentation.title(for: lane), systemImage: laneSymbol(lane))
                    .font(.callout.weight(.semibold))
                if let requirement = definition?.coverage[lane] {
                    Text(requirementTitle(requirement)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                ScenarioOutcomeBadge(outcome: presentation.outcome(for: lane))
            }
            Text(presentation.summary(for: lane))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !results.isEmpty {
                DisclosureGroup("Checks and evidence") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(results) { result in
                            attemptCard(result, run: run, definition: definition)
                        }
                    }.padding(.top, 10)
                }
            }
        }
        .padding(16)
        .workspaceSurface(radius: 10)
    }

    private func attemptCard(_ result: ScenarioLaneResult, run: ScenarioRun, definition: ScenarioDefinition?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Attempt \(result.attempt)").font(.callout.weight(.medium))
                Text(ScenarioReportPresentation.executionTitle(result.executionStatus))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                ScenarioOutcomeBadge(outcome: result.outcome)
            }
            if result.assertionResults.isEmpty {
                Text("No individual result checks were recorded for this attempt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(result.assertionResults) { assertion in
                let expected = definition?.assertions.first { $0.id == assertion.assertionID }
                VStack(alignment: .leading, spacing: 5) {
                    Label(expected.flatMap { $0.explanation.isEmpty ? nil : $0.explanation } ?? assertion.message,
                          systemImage: assertion.passed ? "checkmark.circle" : "xmark.circle")
                        .font(.callout)
                        .foregroundStyle(assertion.passed ? WorkspaceStyle.success : WorkspaceStyle.failure)
                    if !assertion.passed {
                        Text(assertion.message).font(.caption)
                        if let value = expected?.expectedValue {
                            LabeledContent("Expected", value: display(value)).font(.caption)
                        }
                        if let value = assertion.observedValue {
                            LabeledContent("Observed", value: display(value)).font(.caption)
                        }
                    }
                }
            }
            if !result.artifacts.isEmpty {
                WorkspaceFlowLayout(spacing: 12, lineSpacing: 8) {
                    ForEach(result.artifacts) { artifact in
                        Link(destination: coordinator.artifactURL(run: run, artifact: artifact)) {
                            Label(artifact.filename, systemImage: artifactSymbol(artifact.kind))
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .font(.caption).help(artifact.filename)
                    }
                }
            }
            DisclosureGroup("Technical details") {
                VStack(alignment: .leading, spacing: 10) {
                    if let diagnostic = result.diagnostic { Text(diagnostic).font(.callout) }
                    if let proposed = result.proposedCause {
                        Label("Possible cause: \(proposed)", systemImage: "lightbulb")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(result.observations.keys.sorted(), id: \.self) { key in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(key).font(.caption.weight(.medium))
                            Text(display(result.observations[key])).font(.callout).textSelection(.enabled)
                            if let source = result.observationSources?[key] {
                                Text("Source: \(source)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.padding(.top, 8)
            }
        }
        .padding(14)
        .workspaceInset(radius: 8)
    }

    private var resultsHelp: some View {
        DisclosureGroup("What do the results mean?") {
            VStack(alignment: .leading, spacing: 10) {
                summaryField("Passed", value: "The required checks matched. This only covers what the test checked.")
                summaryField("Failed", value: "A required check did not match the expected result.")
                summaryField("Needs review", value: "Review the captured evidence to assess the result.")
                summaryField("Not observed", value: "There was not enough evidence to verify the result.")
                summaryField("Not applicable", value: "This part was not tested.")
            }.padding(.top, 10)
        }
    }

    private func environmentSection(_ run: ScenarioRun) -> some View {
        DisclosureGroup("Device and software") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Device", value: run.environment.deviceModel)
                LabeledContent("OS", value: run.environment.operatingSystem)
                LabeledContent("Xcode", value: run.environment.xcodeVersion)
                LabeledContent("SDK", value: run.environment.sdkVersion)
                LabeledContent("Language / region", value: "\(run.environment.languageCode) / \(run.environment.regionCode)")
                LabeledContent("Siri configuration", value: run.environment.siriConfiguration ?? "Unknown")
                Text("The same OS version does not guarantee the same Siri model or result.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption).padding(.top, 8)
        }
    }

    @ViewBuilder private func comparisonSection(_ run: ScenarioRun) -> some View {
        if let comparison = coordinator.comparison(for: run) {
            DisclosureGroup("Compare with a previous run") {
                VStack(alignment: .leading, spacing: 7) {
                    Text(comparison.summary).font(.caption)
                    ForEach(comparison.dimensions.filter { !$0.compatible }) { dimension in
                        Text("\(dimension.name): \(dimension.baseline) → \(dimension.candidate)")
                            .font(.caption).foregroundStyle(WorkspaceStyle.warning)
                    }
                }.padding(.top, 8)
            }
        }
    }

    private func releaseSection(_ run: ScenarioRun) -> some View {
        let report = coordinator.releaseReport(for: run)
        return DisclosureGroup("Release requirements") {
            VStack(alignment: .leading, spacing: 6) {
                Text(report.summary).font(.caption)
                ForEach(report.failures, id: \.self) {
                    Label($0, systemImage: "xmark.circle").font(.caption).foregroundStyle(WorkspaceStyle.failure)
                }
            }.padding(.top, 8)
        }
    }

    private func requirementTitle(_ requirement: ScenarioLaneRequirement) -> String {
        switch requirement {
        case .required: "Required"
        case .optional: "Optional"
        case .notApplicable: "Not included"
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
