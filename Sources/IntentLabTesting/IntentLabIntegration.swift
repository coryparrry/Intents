import IntentLabContracts
import Foundation
import XCTest

/// Consumer-owned, compiled operations. Scenario text never becomes executable code.
@available(macOS 27.0, iOS 27.0, *)
@MainActor
public protocol IntentLabIntegration {
    /// Capabilities backed by compiled operations in this consumer target.
    var supportedCapabilities: Set<String> { get }
    /// Prepare an isolated dataset and launch the application for one attempt.
    func prepare(bundleIdentifier: String, context: String, operationID: String) throws -> XCUIApplication
    /// Read application state independently of the scenario's expected values.
    func observe(application: XCUIApplication) throws -> [String: IntentLabValue]
    /// Require a fresh action receipt, in addition to the attempt context.
    func completed(observations: [String: IntentLabValue], context: String) -> Bool
    /// Provenance of each observed key; unlisted keys default to accessible UI.
    func source(for observationKey: String) -> String
}

@available(macOS 27.0, iOS 27.0, *)
public extension IntentLabIntegration {
    func source(for observationKey: String) -> String { "accessibleUI" }

    /// Merge consumer observations with declaration-backed generic queries.
    func observe(
        application: XCUIApplication,
        declaration: IntentLabIntegrationDeclaration?,
        deadlineSeconds: TimeInterval
    ) throws -> [String: IntentLabValue] {
        var observations = try observe(application: application)
        if let declaration, !(declaration.queryOperations ?? []).isEmpty {
            let queried = try IntentLabQueryObserver.observe(
                bundleIdentifier: declaration.targetBundleIdentifier,
                declaration: declaration,
                deadlineSeconds: deadlineSeconds
            )
            for (key, value) in queried {
                if let existing = observations[key], existing != value {
                    throw IntentLabQueryObservationError.invalidValue(key)
                }
                observations[key] = value
            }
        }
        return observations
    }
}

public enum IntentLabIntegrationError: LocalizedError {
    case unsupportedPreparation(String)
    public var errorDescription: String? {
        switch self {
        case .unsupportedPreparation(let operation):
            "The integration does not provide preparation operation \(operation)."
        }
    }
}

/// Minimal consumer for direct, read-only Basic checks. It supplies no state proof.
@available(macOS 27.0, iOS 27.0, *)
@MainActor
public struct IntentLabBasicIntegration: IntentLabIntegration {
    public init() {}
    public var supportedCapabilities: Set<String> {
        ["environment-payload", "direct-intent-execution", "direct-intent-output",
         "entity-query", "value-query"]
    }

    public func prepare(bundleIdentifier: String, context: String, operationID: String) throws -> XCUIApplication {
        guard ["none", "noop", "readOnly"].contains(operationID) else {
            throw IntentLabIntegrationError.unsupportedPreparation(operationID)
        }
        let application = XCUIApplication(bundleIdentifier: bundleIdentifier)
        application.launch()
        return application
    }

    public func observe(application: XCUIApplication) throws -> [String: IntentLabValue] { [:] }
    public func completed(observations: [String: IntentLabValue], context: String) -> Bool { false }
}
