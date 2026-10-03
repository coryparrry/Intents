import SwiftUI

/// Visible guidance stays beside the control, including when its value is filled in.
struct IntentLabHelp: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum IntentLabGuidance {
    static func assertion(_ kind: ScenarioAssertionKind) -> String {
        switch kind {
        case .entityIdentifier:
            "Entity ID checks which item the app selected, such as the saved ID of a note. Use the item's stable ID, not its display name."
        case .returnedField:
            "Returned field checks a value reported by the app, such as a note title. Your test support must capture it."
        case .visibleText:
            "Visible text checks text captured from the screen. The test support must report that text under the observation key."
        case .stateTransition:
            "State change compares a reported state with your expected value, such as a task being complete. Your test support must capture the relevant state."
        case .noMutation:
            "No mutation compares your test support’s unchanged-data observation with the expected value. Intent Lab does not independently check all app data for changes."
        case .semanticRubric:
            "Semantic review judges meaning or quality using your written criteria. It needs review and cannot prove an exact match by itself."
        }
    }

    static func requirement(_ requirement: ScenarioLaneRequirement) -> String {
        switch requirement {
        case .required: "Required: this result must pass for the whole scenario to pass."
        case .optional: "Optional: collect this result without counting it toward the overall outcome. A failure can still make the Xcode test fail."
        case .notApplicable: "Not applicable: skip this part because it does not apply to this scenario."
        }
    }
}
