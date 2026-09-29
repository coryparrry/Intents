#if DEBUG && INTENT_LAB_TEST_SUPPORT
import AppIntents
import Foundation
import IntentLabContracts

/// Register only explicit production service operations here. Each operation
/// must call the app's production service and record a productionService receipt
/// at that service entry point. Never synthesize a receipt in the wrapper.
protocol IntentLabFeatureTestSupport: Sendable {
    var supportedOperationIDs: Set<String> { get }
    func prepare(operationID: String, context: String) async throws
    func invokeFeature(operationID: String, businessInput: String, context: String) async throws -> String
    func snapshot(operationID: String, context: String) async throws -> String
    func cleanup(operationID: String, context: String) async throws
}

/// Install the app-owned adapter during app startup before the test intent runs.
enum IntentLabFeatureTestSupportRegistry {
    private static let store = IntentLabFeatureTestSupportStore()

    static var current: (any IntentLabFeatureTestSupport)? { store.current }

    static func install(_ support: any IntentLabFeatureTestSupport) {
        store.install(support)
    }
}

private final class IntentLabFeatureTestSupportStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (any IntentLabFeatureTestSupport)?

    var current: (any IntentLabFeatureTestSupport)? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func install(_ support: any IntentLabFeatureTestSupport) {
        lock.lock()
        defer { lock.unlock() }
        value = support
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct IntentLabInvokeFeatureIntent: AppIntent {
    static let title: LocalizedStringResource = "Invoke Intent Lab feature"
    static let isDiscoverable = false
    static let openAppWhenRun = true

    @Parameter(title: "Operation") var operationID: String
    @Parameter(title: "Business input") var businessInput: String
    @Parameter(title: "Intent Lab context") var context: String

    func perform() async throws -> some IntentResult & ReturnsValue<IntentLabFeatureTestResult> {
        guard let support = IntentLabFeatureTestSupportRegistry.current else {
            throw IntentLabFeatureTestSupportError.notRegistered
        }
        guard support.supportedOperationIDs.contains(operationID) else {
            throw IntentLabFeatureTestSupportError.unsupportedOperation(operationID)
        }
        let response = try await support.invokeFeature(
            operationID: operationID,
            businessInput: businessInput,
            context: context
        )
        return .result(value: IntentLabFeatureTestResult(response: response))
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct IntentLabFeatureTestResult: AppEntity, Identifiable {
    var id: String { response }
    @Property(title: "Response") var response: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Intent Lab feature response"
    static let defaultQuery = IntentLabFeatureTestResultQuery()
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(response)") }

    init(response: String) { self.response = response }
}

@available(iOS 27.0, macOS 27.0, *)
struct IntentLabFeatureTestResultQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [IntentLabFeatureTestResult] { [] }
}

private enum IntentLabFeatureTestSupportError: LocalizedError {
    case notRegistered
    case unsupportedOperation(String)

    var errorDescription: String? {
        switch self {
        case .notRegistered: "Register the app-owned Intent Lab feature support before invoking the test intent."
        case .unsupportedOperation(let operationID): "The app does not support local feature operation \(operationID)."
        }
    }
}
#endif
