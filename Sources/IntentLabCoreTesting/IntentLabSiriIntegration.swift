import Foundation
import IntentLabContracts
import XCTest

/// Consumer-owned UI operations used by the XCTest-only Siri runner.
@available(macOS 27.0, iOS 27.0, *)
@MainActor
public protocol IntentLabSiriIntegration {
    var supportedCapabilities: Set<String> { get }
    func prepare(bundleIdentifier: String, context: String, operationID: String) throws -> XCUIApplication
    func observe(application: XCUIApplication) throws -> [String: IntentLabValue]
    func observe(
        application: XCUIApplication,
        declaration: IntentLabIntegrationDeclaration?,
        deadlineSeconds: TimeInterval
    ) throws -> [String: IntentLabValue]
    func completed(observations: [String: IntentLabValue], context: String) -> Bool
    func source(for observationKey: String) -> String
    /// Whether this integration prepares isolated fixtures for mutating checks.
    var supportsMutatingChecks: Bool { get }
}

@available(macOS 27.0, iOS 27.0, *)
public extension IntentLabSiriIntegration {
    func source(for observationKey: String) -> String { "accessibleUI" }
    var supportsMutatingChecks: Bool { true }

    func observe(
        application: XCUIApplication,
        declaration: IntentLabIntegrationDeclaration?,
        deadlineSeconds: TimeInterval
    ) throws -> [String: IntentLabValue] {
        try observe(application: application)
    }
}

public enum IntentLabExecutionPathError: LocalizedError {
    case directIntentRequired
    case queryObservationRequired
    case unsafePreparation

    public var errorDescription: String? {
        switch self {
        case .directIntentRequired:
            "This scenario requires direct intent execution. Add the IntentLabTesting product or run a Siri-only scenario."
        case .queryObservationRequired:
            "This scenario requires an App Intents query observation. Add the IntentLabTesting product or remove the query requirement."
        case .unsafePreparation:
            "The integration does not provide isolated preparation for this mutating check."
        }
    }
}

/// Indicates that a direct intent may still complete after the deadline.
public struct IntentLabDirectIntentTimeout: LocalizedError {
    public init() {}
    public var errorDescription: String? { "The direct intent did not finish before the scenario deadline." }
}
