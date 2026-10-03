import Foundation
import IntentLabContracts
@_exported import IntentLabCoreTesting
import XCTest

/// Existing direct + Siri facade. Shared validation and evidence live in IntentLabCoreTesting.
@available(macOS 27.0, iOS 27.0, *)
@MainActor
public enum IntentLabScenarioRunner {
    public static let packageVersion = IntentLabScenarioEngine.packageVersion

    public static func checkConnection(
        testCase: XCTestCase,
        integration: any IntentLabIntegration
    ) throws {
        try IntentLabScenarioEngine.checkConnection(testCase: testCase, integration: integration)
    }

    /// Launches the selected app through its declared harmless preparation,
    /// observes its state, and runs only the payload-free readiness intent.
    public static func testIntentLabReadiness(
        testCase: XCTestCase,
        integration: any IntentLabIntegration
    ) throws {
        try IntentLabScenarioEngine.testIntentLabReadiness(
            testCase: testCase,
            integration: integration,
            directReadinessExecutor: readinessObservations
        )
    }

    @discardableResult
    public static func run(
        testCase: XCTestCase,
        integration: any IntentLabIntegration,
        scenario scenarioOverride: IntentLabScenario? = nil,
        invocation invocationOverride: IntentLabInvocation? = nil
    ) throws -> IntentLabEvidenceEnvelope {
        try IntentLabScenarioEngine.run(
            testCase: testCase,
            integration: integration,
            scenario: scenarioOverride,
            invocation: invocationOverride,
            directExecutor: directObservations(for:),
            supportsQueryOperations: true,
            featureExecutor: featureObservations
        )
    }

    private static func featureObservations(
        bundleIdentifier: String,
        control: IntentLabIntegrationDeclaration.FeatureControl,
        parameters: [String: IntentLabValue],
        context: String,
        deadlineSeconds: TimeInterval
    ) throws -> [String: IntentLabValue] {
        let completed = XCTestExpectation(description: "Local feature test intent completed")
        var result: Result<IntentLabTestIntentResult, Error>?
        let task = Task { @MainActor in
            do {
                result = .success(try await IntentLabTestIntentTransport.invoke(
                    bundleIdentifier: bundleIdentifier,
                    control: control,
                    parameters: parameters,
                    context: context
                ))
            } catch {
                result = .failure(error)
            }
            completed.fulfill()
        }
        defer { task.cancel() }
        guard XCTWaiter.wait(for: [completed], timeout: deadlineSeconds) == .completed,
              let result else {
            throw IntentLabDirectIntentTimeout()
        }
        return try result.get().observations
    }

    private static func readinessObservations(
        bundleIdentifier: String,
        declaration: IntentLabIntegrationDeclaration,
        context: String,
        deadlineSeconds: TimeInterval
    ) throws -> [String: IntentLabValue] {
        let completed = XCTestExpectation(description: "IntentLab readiness intent completed")
        var result: Result<IntentLabReadinessTestIntentResult, Error>?
        let task = Task { @MainActor in
            do {
                result = .success(try await IntentLabReadinessTestIntentTransport.invoke(
                    bundleIdentifier: bundleIdentifier,
                    declaration: declaration,
                    context: context
                ))
            } catch {
                result = .failure(error)
            }
            completed.fulfill()
        }
        defer { task.cancel() }
        guard XCTWaiter.wait(for: [completed], timeout: deadlineSeconds) == .completed,
              let result else {
            throw IntentLabDirectIntentTimeout()
        }
        return try result.get().observations
    }

    // Siri remains on XCTest's synchronous invocation stack while direct intents
    // run in a bounded task. A timed-out action fences all later attempts.
    private static func directObservations(for scenario: IntentLabScenario) throws -> [String: IntentLabValue] {
        let completed = XCTestExpectation(description: "Direct intent completed")
        var result: Result<[String: IntentLabValue], Error>?
        let task = Task { @MainActor in
            do { result = .success(try await IntentProbe.run(scenario)) }
            catch { result = .failure(error) }
            completed.fulfill()
        }
        defer { task.cancel() }
        guard XCTWaiter.wait(for: [completed], timeout: scenario.safety.deadlineSeconds) == .completed,
              let result else {
            throw IntentLabDirectIntentTimeout()
        }
        return try result.get()
    }
}
