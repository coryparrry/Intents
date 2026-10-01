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

    func cleanup(bundleIdentifier: String, context: String, operationID: String) throws {
        guard ["", "reset", "resetNotes", "resetFixture"].contains(operationID) else {
            throw IntentLabIntegrationError.unsupportedCleanup(operationID)
        }
        let application = try prepare(bundleIdentifier: bundleIdentifier, context: context, operationID: operationID)
        defer { application.terminate() }
        let selected = application.staticTexts["intent-lab-selected-note-id"]
        let mutations = application.staticTexts["intent-lab-mutation-count"]
        let event = application.staticTexts["intent-lab-last-event"]
        guard selected.waitForExistence(timeout: 5), selected.label == "none",
              mutations.label == "0", event.label == "none" else {
            throw NotesCleanupError.resetNotObserved
        }
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
            observations["visibleResponse"] = .string(event.label)
        }
        return observations
    }

    func completed(observations: [String: IntentLabValue], context: String) -> Bool {
        guard observations["invocationContext"] == .string(context),
              case .string(let selectedID) = observations["selectedNoteID"],
              selectedID != "none", !selectedID.isEmpty,
              case .string(let event) = observations["applicationEvent"],
              event != "none", !event.isEmpty else { return false }
        return true
    }

    func source(for observationKey: String) -> String { "accessibleUI" }
}

private enum NotesCleanupError: LocalizedError {
    case resetNotObserved
    var errorDescription: String? { "The synthetic note fixture did not return to its empty baseline." }
}
