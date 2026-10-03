import XCTest

@MainActor
enum FixtureBridge {
    static func resetAndLaunch(
        bundleIdentifier: String,
        context: String,
        resetArgument: String = "-intent-lab-reset"
    ) -> XCUIApplication {
        let application = XCUIApplication(bundleIdentifier: bundleIdentifier)
        application.launchArguments = [resetArgument, "-intent-lab-context", context]
        application.launch()
        return application
    }

    static func observations(from application: XCUIApplication) -> [String: IntentLabValue] {
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
}
