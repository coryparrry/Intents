import Foundation
import XCTest
import IntentLabContracts
import IntentLabCoreTesting

/// Reads the fixture snapshot once per poll, avoiding redundant field queries.
/// Completion still uses the full fresh Summary receipt predicate.
@available(iOS 27.0, *)
@MainActor
struct PresetPhoneIntegration: IntentLabSiriIntegration {
    private let base = NotesIntentLabIntegration()
    var supportedCapabilities: Set<String> { base.supportedCapabilities }
    func prepare(bundleIdentifier: String, context: String, operationID: String) throws -> XCUIApplication {
        try base.prepare(bundleIdentifier: bundleIdentifier, context: context, operationID: operationID)
    }
    func cleanup(bundleIdentifier: String, context: String, operationID: String) throws {
        guard ["", "reset", "resetNotes", "resetFixture"].contains(operationID) else {
            throw IntentLabExecutionPathError.cleanupUnsupported(operationID)
        }
        let app = XCUIApplication(bundleIdentifier: bundleIdentifier)
        app.launchArguments = ["-intent-lab-cleanup", "-intent-lab-operation", operationID, "-intent-lab-context", context]
        app.launch()
        defer { app.terminate() }
        try NotesIntentLabIntegration.verifyReset(observe(application: app))
    }
    func observe(application: XCUIApplication) throws -> [String: IntentLabValue] {
        let element = application.staticTexts["intentlab.fixtureSnapshot"]
        guard element.exists, let data = element.label.data(using: .utf8),
              let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var values: [String: IntentLabValue] = [:]
        for key in ["selectedNoteID", "invocationContext", "applicationEvent"] {
            if let value = snapshot[key] as? String { values[key] = .string(value) }
        }
        if let count = snapshot["noteStoreMutationCount"] as? Int { values["noteStoreMutationCount"] = .integer(Int64(count)) }
        if let digest = snapshot["fixtureDigest"] as? String { values["intentlab.fixtureDigest"] = .string(digest) }
        if case .string(let event) = values["applicationEvent"], event.hasPrefix("SummarizeNoteIntent:") {
            for (key, id) in [
                ("visibleSummary", "intent-lab-visible-summary"),
                ("summarySourceNoteID", "intent-lab-summary-source-note-id"),
                ("summarySourceContentDigest", "intent-lab-summary-source-digest"),
                ("summaryContext", "intent-lab-summary-context"),
                ("summaryCompletionID", "intent-lab-summary-completion-id")
            ] {
                let item = application.staticTexts[id]
                if item.exists { values[key] = .string(item.label) }
            }
        }
        return values
    }
    func completed(observations: [String: IntentLabValue], context: String) -> Bool {
        base.completed(observations: observations, context: context)
    }
}
