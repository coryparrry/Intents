import AppIntents
import SwiftUI

@main
struct MacIntentSampleApp: App {
    /// Refresh the sample app shortcut parameters when the application initializes.
    init() { SampleShortcuts.updateAppShortcutParameters() }
    var body: some Scene {
        WindowGroup { Text("Mac App Intent testing sample").padding() }
    }
}

struct SampleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ReadSampleStatus(), phrases: ["Read status in \(.applicationName)"],
                    shortTitle: "Read status", systemImageName: "checkmark.circle")
    }
}

struct ReadSampleStatus: AppIntent {
    static let title: LocalizedStringResource = "Read sample status"
    /// Return the fixed ready status for read-only native intent checks.
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: "ready")
    }
}

struct FormatSampleInput: AppIntent {
    static let title: LocalizedStringResource = "Format sample input"
    @Parameter(title: "Text") var text: String
    @Parameter(title: "Count") var count: Int
    @Parameter(title: "Enabled") var enabled: Bool
    /// Return all supplied parameter values in a stable colon-separated string for conversion checks.
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: "\(text):\(count):\(enabled)")
    }
}

struct ScaleSampleNumber: AppIntent {
    static let title: LocalizedStringResource = "Scale sample number"
    @Parameter(title: "Number") var number: Double
    /// Return twice the supplied number to expose numeric input and output conversion.
    func perform() async throws -> some IntentResult & ReturnsValue<Double> {
        .result(value: number * 2)
    }
}

enum SampleMode: String, AppEnum {
    case short, long
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Sample mode"
    static let caseDisplayRepresentations: [SampleMode: DisplayRepresentation] = [
        .short: "Short", .long: "Long"
    ]
}

struct ReadSampleMode: AppIntent {
    static let title: LocalizedStringResource = "Read sample mode"
    @Parameter(title: "Mode", default: .short) var mode: SampleMode
    /// Return the selected enum raw value, using the declared short-mode default when omitted.
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: mode.rawValue)
    }
}
