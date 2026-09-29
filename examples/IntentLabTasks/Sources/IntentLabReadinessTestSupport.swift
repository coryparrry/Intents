#if DEBUG && INTENT_LAB_TEST_SUPPORT
import AppIntents
import Foundation

@available(iOS 27.0, macOS 27.0, *)
struct IntentLabReadinessIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Intent Lab app readiness"
    static let isDiscoverable = false
    static let openAppWhenRun = true

    @Parameter(title: "Intent Lab context") var context: String

    func perform() async throws -> some IntentResult & ReturnsValue<IntentLabReadinessTestResult> {
        guard !context.isEmpty else {
            throw IntentLabReadinessTestSupportError.invalidContext
        }
        return .result(value: IntentLabReadinessTestResult(ready: true, context: context))
    }
}

/// A successful response proves this Debug-only support intent is present
/// in the selected app build. It does not claim that any Feature ran.
@available(iOS 27.0, macOS 27.0, *)
struct IntentLabReadinessTestResult: AppEntity, Identifiable {
    var id: String { context }
    @Property(title: "Ready") var ready: Bool
    @Property(title: "Context") var context: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Intent Lab app readiness"
    static let defaultQuery = IntentLabReadinessTestResultQuery()
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: ready ? "Ready" : "Not ready")
    }

    init(ready: Bool, context: String) {
        self.ready = ready
        self.context = context
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct IntentLabReadinessTestResultQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [IntentLabReadinessTestResult] { [] }
}

private enum IntentLabReadinessTestSupportError: LocalizedError {
    case invalidContext

    var errorDescription: String? {
        "The Intent Lab readiness check requires a non-empty context."
    }
}
#endif
