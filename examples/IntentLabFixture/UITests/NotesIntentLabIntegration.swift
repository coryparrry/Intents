import Foundation
import IntentLabContracts
import IntentLabTesting
import XCTest

@available(iOS 27.0, *)
@MainActor
struct NotesIntentLabIntegration: IntentLabIntegration {
    var supportedCapabilities: Set<String> {
        ["environment-payload", "direct-intent-execution", "direct-intent-output",
         "preparation", "accessible-result", "siri", "siri-completion", "invocation-correlation"]
    }
    func prepare(bundleIdentifier: String, context: String, operationID: String) throws -> XCUIApplication {
        guard ["", "reset", "resetNotes", "resetFixture"].contains(operationID) else {
            throw IntentLabIntegrationError.unsupportedPreparation(operationID)
        }
        let application = XCUIApplication(bundleIdentifier: bundleIdentifier)
        application.launchArguments = ["-intent-lab-reset", "-intent-lab-context", context]
        application.launch()
        return application
    }

    func observe(application: XCUIApplication) throws -> [String: IntentLabValue] {
        var observations: [String: IntentLabValue] = [:]
        let selected = application.staticTexts["intent-lab-selected-note-id"]
        if selected.waitForExistence(timeout: 2) { observations["selectedNoteID"] = .string(selected.label) }
        let mutation = application.staticTexts["intent-lab-mutation-count"]
        if mutation.exists, let count = Int64(mutation.label) { observations["noteStoreMutationCount"] = .integer(count) }
        let context = application.staticTexts["intent-lab-observed-context"]
        if context.exists { observations["invocationContext"] = .string(context.label) }
        let event = application.staticTexts["intent-lab-last-event"]
        if event.exists {
            observations["applicationEvent"] = .string(event.label)
        }
        let summary = application.staticTexts["intent-lab-visible-summary"]
        if summary.exists, !summary.label.isEmpty {
            observations["visibleSummary"] = .string(summary.label)
            observations["visibleResponse"] = .string(summary.label)
        }
        for (key, selector) in [
            ("summarySourceNoteID", "intent-lab-summary-source-note-id"),
            ("summarySourceContentDigest", "intent-lab-summary-source-digest"),
            ("summaryContext", "intent-lab-summary-context"),
            ("summaryCompletionID", "intent-lab-summary-completion-id"),
            ("summaryCaseID", "intent-lab-summary-case-id"),
            ("summaryAttemptID", "intent-lab-summary-attempt-id")
        ] {
            let element = application.staticTexts[selector]
            if element.exists, !element.label.isEmpty {
                observations[key] = .string(element.label)
            }
        }
        return observations
    }

    func completed(observations: [String: IntentLabValue], context: String) -> Bool {
        guard observations["invocationContext"] == .string(context),
              case .string(let selectedID) = observations["selectedNoteID"],
              selectedID != "none", !selectedID.isEmpty,
              case .string(let event) = observations["applicationEvent"],
              event != "none", !event.isEmpty else { return false }
        if event == "OpenNoteIntent:\(selectedID)" { return true }
        guard ["SummarizeNoteIntent", "AppFeature", "AppUI"].contains(where: { event == "\($0):\(selectedID)" }) else {
            return false
        }
        guard observations["summaryContext"] == .string(context),
              observations["summarySourceNoteID"] == .string(selectedID),
              case .string(let summary) = observations["visibleSummary"],
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              case .string(let digest) = observations["summarySourceContentDigest"],
              digest.count == 64, digest.allSatisfy({ $0.isHexDigit }),
              case .string(let completionID) = observations["summaryCompletionID"], UUID(uuidString: completionID) != nil else {
            return false
        }
        return true
    }

    func source(for observationKey: String) -> String { "accessibleUI" }
}
