import AppKit
import MacIntentTesting
import SwiftUI

/// Displays Apple verdicts and local observations for a selected turn across repeats.
struct SiriStudioInspector: View {
    let run: SiriStudioRunRecord
    let result: SiriStudioScenarioResult
    let turnID: UUID?
    let stale: Bool
    var showsAdvanced = false
    var actions: [MacIntentAction] = []
    @State private var selectedTurnID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(stale ? "Stale result · \(result.state.label)" : result.state.label).font(.headline)
            if let reason = result.reason { Text(reason).font(.callout).textSelection(.enabled) }
            if showsAdvanced, let passed = result.passed {
                Text("\(passed) of \(result.attempted) repeats passed").font(.caption)
            } else if showsAdvanced && result.attempted > 1 {
                Text("Apple’s available metrics don’t identify how many repeats passed.").font(.caption)
            }
            if showsAdvanced && !result.failingMetrics.isEmpty {
                LabeledContent("Apple’s failing metrics", value: result.failingMetrics.joined(separator: ", "))
            }
            if showsAdvanced, let summary = result.summary {
                ForEach(summary.metrics.keys.sorted(), id: \.self) { name in
                    LabeledContent(name, value: (summary.metrics[name] ?? 0).formatted(.percent))
                }
            }
            if !result.reports.isEmpty {
                if historicalTurns.count > 1 {
                    Picker("Observed turn", selection: Binding(
                        get: { displayedTurnID }, set: { selectedTurnID = $0 }
                    )) {
                        ForEach(Array(historicalTurns.enumerated()), id: \.element) { index, id in
                            Text("Turn \(index + 1)").tag(Optional(id))
                        }
                    }
                }
                repeats
            }
            if showsAdvanced { DisclosureGroup("Run facts and evidence") { facts.padding(.top, 6) } }
        }
    }

    /// The snapshot that authored the observed turn, unavailable for an unmatched imported revision.
    private var authored: SiriStudioScenario? {
        run.document.scenarios.first { $0.id == result.id && $0.revision == result.revision }
    }

    /// Shows repeats in comparable columns, with missing evidence visible as its own column.
    @ViewBuilder private var repeats: some View {
        let count = max(result.attempted, (result.reports.map(\.repeatIndex).max() ?? -1) + 1)
        if count == 1 {
            repeatColumn(0).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(0..<count, id: \.self) { index in
                        repeatColumn(index).frame(width: 280, alignment: .leading)
                    }
                }
            }
        }
    }

    /// Renders a repeat's Apple metrics, blocked cause, or selected turn.
    private func repeatColumn(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsAdvanced || result.attempted > 1 { Text("Repeat \(index + 1)").font(.subheadline.weight(.semibold)) }
            if showsAdvanced, let metrics = result.summary?.perRepeat?.first(where: { $0.repeatIndex == index })?.metrics {
                ForEach(metrics.keys.sorted(), id: \.self) { name in
                    LabeledContent(name, value: (metrics[name] ?? 0).formatted(.percent)).font(.caption)
                }
            }
            if let report = result.reports.first(where: { $0.repeatIndex == index }) {
                if let blocked = report.blocked {
                    Text("Blocked during \(blocked.phase.rawValue): \(blocked.message)").textSelection(.enabled)
                    Text(blocked.errorType).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(report.turnsReached) of \(report.turnsAuthored) turns reached")
                        .font(.caption).foregroundStyle(.secondary)
                    if let turn = observedTurn(report) { turnDetail(turn) }
                    else { Text("This repeat didn’t reach the selected turn.").font(.caption) }
                }
            } else { Text("No report was recorded.").font(.caption) }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Gets turn IDs from the fullest transcript so a stale result remains navigable.
    private var historicalTurns: [UUID] {
        result.reports.max(by: { $0.turns.count < $1.turns.count })?.turns.map(\.id) ?? []
    }

    /// Keeps every observed turn selectable on Results, including current and historical conversations.
    private var displayedTurnID: UUID? {
        [selectedTurnID, turnID].compactMap { $0 }.first(where: historicalTurns.contains) ?? historicalTurns.first
    }

    /// Resolves the chosen turn even when it belongs to a historical revision.
    private func observedTurn(_ report: SiriStudioReport) -> SiriStudioReport.Turn? {
        guard let id = displayedTurnID else { return report.turns.first }
        return report.turns.first { $0.id == id }
    }

    /// Pairs expected calls with observations and lists uncovered calls separately.
    private func turnDetail(_ observed: SiriStudioReport.Turn) -> some View {
        let turn = authored?.turns.first { $0.id == observed.id }
        let local = turn?.expectations ?? .init()
        let whole = authored?.scenarioExpectations ?? .init()
        let invocations = observed.invocations.sorted { $0.timestamp < $1.timestamp }
        let required = local.calls
        let forbidden = local.forbidden + whole.forbidden
        let covered = Set((showsAdvanced ? required + forbidden + whole.calls : required).map(\.actionIdentifier))
        let other = invocations.filter { !belongsToApp($0) || !covered.contains($0.intent) }
        return VStack(alignment: .leading, spacing: 7) {
            Text(observed.utterance).font(.callout).textSelection(.enabled)
            if !required.isEmpty || !forbidden.isEmpty || !whole.calls.isEmpty {
                Text("Expected and observed calls").font(.subheadline.weight(.semibold))
                ForEach(required) { call in comparison(call, in: invocations, kind: "Required") }
                if showsAdvanced {
                    ForEach(whole.calls) { call in comparison(call, in: invocations, kind: "Required across scenario") }
                    ForEach(forbidden) { call in comparison(call, in: invocations, kind: "Forbidden") }
                }
            }
            if !other.isEmpty {
                Text(authored == nil ? "Observed calls" : "Additional calls").font(.subheadline.weight(.semibold))
                ForEach(other.indices, id: \.self) { invocation(other[$0]) }
            }
            if let response = observed.response {
                Text("Siri’s reply").font(.subheadline.weight(.semibold))
                Text(response.text).textSelection(.enabled)
                if showsAdvanced { Text(response.timestamp).font(.caption).foregroundStyle(.secondary) }
                if showsAdvanced {
                    ForEach(local.replyContains.indices, id: \.self) { index in
                        let check = local.replyContains[index]
                        let matched = response.text.range(of: check.text, options: check.caseSensitive ? [] : .caseInsensitive) != nil
                        Text("Intents check: \(matched ? "Found" : "Didn’t find") “\(check.text)”")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Labels local hints explicitly so they cannot be mistaken for Apple's scenario verdict.
    private func comparison(_ call: SiriStudioCall, in invocations: [SiriStudioReport.Invocation], kind: String) -> some View {
        let matches = invocations.filter { belongsToApp($0) && $0.intent == call.actionIdentifier }
        let forbidden = kind == "Forbidden"
        let hint = hint(for: call, in: matches, forbidden: forbidden)
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(kind): \(title(for: call.actionIdentifier))").font(.callout.weight(.medium))
            if showsAdvanced {
                ForEach(call.arguments, id: \.parameterIdentifier) { argument in
                    Text("\(argument.parameterIdentifier): \(argument.matcher.displayValue)").font(.caption)
                }
                if let expected = call.result { Text("Result: \(expected.displayValue)").font(.caption) }
            }
            ForEach(matches.indices, id: \.self) { invocation(matches[$0]) }
            if let hint {
                Text(showsAdvanced ? "Intents check (unconfirmed): \(hint)" : hint).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Shows an invocation's outcome, arguments, result text, and observed timestamp.
    private func invocation(_ invocation: SiriStudioReport.Invocation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title(for: invocation.intent)) · \(invocation.outcome)").font(.caption.weight(.medium))
            if showsAdvanced {
                ForEach(invocation.arguments.keys.sorted(), id: \.self) { name in
                    Text("\(name): \(invocation.arguments[name] ?? "")").font(.caption).textSelection(.enabled)
                }
                if let result = invocation.result { Text("Result: \(result)").font(.caption).textSelection(.enabled) }
                Text(invocation.timestamp).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// Uses an action's display name in the simple result and preserves identifiers in Advanced evidence.
    private func title(for identifier: String) -> String {
        showsAdvanced ? identifier : actions.first { $0.id == identifier }?.title ?? identifier
    }

    /// Disambiguates identical intent names belonging to different apps.
    private func belongsToApp(_ invocation: SiriStudioReport.Invocation) -> Bool {
        invocation.bundleIdentifier == nil || invocation.bundleIdentifier == run.document.bundleIdentifier
    }

    /// Checks only clear text differences and completed/confirmation outcomes, leaving grading to Apple.
    private func hint(for call: SiriStudioCall, in observations: [SiriStudioReport.Invocation], forbidden: Bool) -> String? {
        if forbidden {
            guard call.arguments.isEmpty,
                  observations.contains(where: { $0.ran || $0.outcome == "awaitingConfirmation" }) else { return nil }
            return "Siri ran this forbidden action or asked to confirm it."
        }
        guard !observations.isEmpty else { return "No invocation was observed on this turn." }
        let completed = observations.filter { $0.outcome == "succeeded" }
        guard !completed.isEmpty else { return "No invocation completed successfully." }
        let differences = call.arguments.compactMap { argument -> String? in
            guard let expected = argument.matcher.comparableText, completed.allSatisfy({
                guard let actual = $0.arguments[argument.parameterIdentifier] else { return false }
                return actual != expected
            }) else { return nil }
            return argument.parameterIdentifier
        }
        return differences.isEmpty ? nil : "Observed text differs for \(differences.joined(separator: ", "))."
    }

    /// Links local evidence and gives the frozen build and revision details.
    private var facts: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Scenario revision \(result.revision)")
            Text("Started \(run.startedAt.formatted()) · ended \(run.endedAt.formatted())")
            Text(run.osBuild)
            if let xcode = run.xcodeBuild { Text(xcode) }
            if let arguments = run.appLaunchArguments {
                Text(arguments.isEmpty ? "App launch: default arguments" : "App launch arguments: " + arguments.joined(separator: " · "))
            } else {
                Text("App launch arguments were not captured for this imported or older run.")
            }
            if let product = run.productIdentity { Text("App build: \(product.sha256.prefix(16))") }
            Button("Show run log") { NSWorkspace.shared.activateFileViewerSelecting([run.logURL]) }
            if let source = run.sourceURL {
                Button("Show generated Swift") { NSWorkspace.shared.activateFileViewerSelecting([source]) }
            }
            if let bundle = run.resultBundleURL { Button("Open Xcode result") { NSWorkspace.shared.open(bundle) } }
        }.font(.caption).textSelection(.enabled)
    }
}

private extension SiriStudioMatcher {
    /// A plain-language description of the expected matcher.
    var displayValue: String {
        switch self {
        case .equals(let value): "equals “\(value)”"
        case .contains(let value): "contains “\(value)”"
        case .containsRegex(let value): "matches regex “\(value)”"
        case .isNil: "is nil"
        case .notNil: "is not nil"
        case .intEquals(let value): "equals \(value)"
        case .doubleEquals(let value): "equals \(value)"
        case .boolEquals(let value): "equals \(value)"
        case .enumCase(let value): "case \(value)"
        case .entityIdentifier(let type, let value): "\(type) ID “\(value)”"
        }
    }

    /// The subset of equality constraints with a useful textual comparison hint.
    var comparableText: String? {
        switch self {
        case .equals(let value): value
        case .intEquals(let value): String(value)
        case .boolEquals(let value): String(value)
        default: nil
        }
    }
}
