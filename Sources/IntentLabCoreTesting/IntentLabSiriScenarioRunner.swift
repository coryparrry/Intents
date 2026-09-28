import IntentLabContracts
import XCTest

/// Runs the approved Siri lane using XCTest and the device UI only.
@available(macOS 27.0, iOS 27.0, *)
@MainActor
public enum IntentLabSiriScenarioRunner {
    public static let packageVersion = IntentLabScenarioEngine.packageVersion

    public static func checkConnection(
        testCase: XCTestCase,
        integration: any IntentLabSiriIntegration
    ) throws {
        try IntentLabScenarioEngine.checkConnection(testCase: testCase, integration: integration)
    }

    @discardableResult
    public static func run(
        testCase: XCTestCase,
        integration: any IntentLabSiriIntegration,
        scenario: IntentLabScenario? = nil,
        invocation: IntentLabInvocation? = nil
    ) throws -> IntentLabEvidenceEnvelope {
        try IntentLabScenarioEngine.run(
            testCase: testCase, integration: integration,
            scenario: scenario, invocation: invocation
        )
    }
}
