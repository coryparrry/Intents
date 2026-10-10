import SwiftUI
import IntentsAutomationCore

/// Shared native results component, also used by the app-first surface.
struct NativeAutomationEvidenceView: View {
    let presentation: AutomationNativeEvidencePresentation
    private var document: AutomationNativeEvidenceDocument { presentation.document }
    @State private var stepLimit = 50
    private var report: AutomationAttemptReport { document.report }
    private var steps: [AutomationNativeEvidenceTimeline.Step] { (try? AutomationNativeEvidenceTimeline.steps(document)) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(document.frozen.plan.execution.operation).font(.headline)
            Text(document.frozen.plan.app.bundleID).font(.caption).foregroundStyle(.secondary)
            Text("Saved result · not reverified").font(.subheadline.weight(.medium))
            Text("Results are shown as recorded. Re-run the case to verify the current app.").font(.caption).foregroundStyle(.secondary)
            LabeledContent("Recorded result", value: summary)
            LabeledContent("Recorded subject", value: report.result.subjectDispatchUncertain ? "Dispatch unresolved" : report.result.subjectCompleted ? "Completed" : report.result.subjectDispatched ? "Dispatched; completion unproven" : "Not dispatched")
            LabeledContent("Recorded assessment", value: report.result.assessed ? "Assessed" : "Unassessed")
            LabeledContent("Recorded evidence", value: report.result.evidenceComplete ? "Complete" : "Incomplete")
            LabeledContent("Controller release", value: report.resourcesReleased ? "Recorded as released" : "Unresolved")
            if !report.result.failedObservations.isEmpty { Text("Failed checks: " + report.result.failedObservations.joined(separator: ", ")) }
            if !report.result.missingObservations.isEmpty { Text("Missing checks: " + report.result.missingObservations.joined(separator: ", ")) }
            DisclosureGroup("Evidence timeline · \(steps.count) steps") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Steps are shown in plan order. Dispatch and release durations were not recorded.").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(steps.prefix(stepLimit))) { step in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .top) {
                                Text(step.phase.rawValue).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(step.operation).font(.subheadline.weight(.medium))
                                    Text(route(step.route)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(step.receipt.map { $0.completed ? "Completed receipt" : $0.dispatched ? "Dispatched receipt" : "Not dispatched" } ?? "No recorded receipt").font(.caption)
                            }
                            if let receipt = step.receipt {
                                ForEach(Array(receipt.observations.enumerated()), id: \.offset) { _, observation in
                                    Text("\(observation.proof.rawValue) · \(observation.collectedAt.formatted(date: .abbreviated, time: .standard)) · \(observation.complete ? "complete" : "incomplete") · \(observation.fresh ? "fresh" : "stale")").font(.caption).textSelection(.enabled)
                                    DisclosureGroup("Observed value") {
                                        let encoded = valueText(observation.value)
                                        Text(String(encoded.prefix(4096))).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                        if encoded.count > 4096 { Text("Showing the first 4096 characters. The complete value is retained in the evidence record.").font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                        }
                        Divider()
                    }
                    if steps.count > stepLimit { Button("Show more steps") { stepLimit += 50 } }
                }.padding(.top, 8)
            }
            DisclosureGroup("Record details") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Attempt: " + report.attemptID)
                    Text("Case: " + document.frozen.digest)
                    Text("Original report: " + document.sourceReportSHA256)
                    Text("Recorded facts retain their original route and proof labels.")
                    Text("Artifacts: \(document.artifacts.count)")
                    ForEach(document.artifacts, id: \.handle) { artifact in Text(artifact.relativePath + " · " + artifact.sha256) }
                }.font(.caption).textSelection(.enabled).padding(.top, 8)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("Native app-check evidence")
    }
    private func valueText(_ value: AutomationValue) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "The recorded value could not be displayed." }
        return String(decoding: data, as: UTF8.self)
    }
    private var summary: String {
        switch report.result.summary {
        case .passed: "Passed"
        case .assertionFailed: "Check failed"
        case .executedUnassessed: "Executed without a business assessment"
        case .needsReview: "Needs review"
        case .unresolved: "Unresolved"
        default: report.result.summary.rawValue
        }
    }
    private func route(_ value: AutomationSegment.Kind) -> String {
        switch value {
        case .ui: "App interface"
        case .systemIntent: "System App Intent"
        case .systemQuery: "System entity query"
        case .siriText: "Siri text route"
        case .pairedFeature: "Paired app feature"
        case .observeOnly: "Observation"
        }
    }
}
