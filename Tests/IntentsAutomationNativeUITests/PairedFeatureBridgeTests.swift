#if os(macOS)
import Foundation
import XCTest
import FoundationEvalsDeveloper
import IntentsAutomationCore
@testable import IntentsAutomationNativeUI

@MainActor final class PairedFeatureBridgeTests: XCTestCase {
    func testRegistrationBindsAppAndFeatureVersionButNotConnectionHeartbeat() throws {
        XCTAssertTrue(AutomationNativePairedClient.supportsTextInput("FoundationEvalsDeveloper.DeveloperTextFeatureInput"))
        XCTAssertFalse(AutomationNativePairedClient.supportsTextInput("Unknown.CustomInput"))
        let feature = DeveloperFeatureDescriptor(id: "answer", displayName: "Answer", version: "1", inputTypeName: String(reflecting: DeveloperTextFeatureInput.self), outputTypeName: String(reflecting: DeveloperFeatureOutput.self))
        var runner = DeveloperRunnerSnapshot(identity: .init(id: UUID(), displayName: "Test app", platform: .mac, operatingSystem: "27", hardwareModel: "Mac", appBundleIdentifier: "example.Test", appVersion: "1.0"), features: [feature], state: .connected)
        let digest = try AutomationNativePairedClient.registration(runner, feature)
        runner.lastSeen = Date().addingTimeInterval(100)
        XCTAssertEqual(try AutomationNativePairedClient.registration(runner, feature), digest)
        runner.identity.appVersion = "1.1"
        XCTAssertNotEqual(try AutomationNativePairedClient.registration(runner, feature), digest)
        runner.identity.appVersion = "1.0"
        var changed = feature; changed.version = "2"
        XCTAssertNotEqual(try AutomationNativePairedClient.registration(runner, changed), digest)
    }

    func testAppFirstInputInvokesExistingRegisteredClosureWithoutExpectedAnswer() async throws {
        let registry = DeveloperFeatureRegistry(), requestID = UUID(), runID = UUID()
        await registry.registerTextFeature(id: "answer", displayName: "Answer", version: "1") { input, context in
            guard input.expected.isEmpty, input.caseID == context.requestID else { throw AutomationContractError.conflictingOperation }
            return DeveloperFeatureOutput(response: input.instructions + ": " + input.prompt)
        }
        let program = AutomationPairedFeatureProgram(runnerID: UUID(), registrationDigest: String(repeating: "a", count: 64), appVersion: "1.0", featureID: "answer", featureVersion: "1", instructions: "Summarize", prompt: "Real subject input")
        let input = AutomationNativePairedClient.input(program: program, requestID: requestID)
        XCTAssertEqual(input.expected, "")
        let result = await registry.execute(.init(id: requestID, runID: runID, featureID: program.featureID, featureVersion: program.featureVersion,
            encodedInput: try JSONEncoder().encode(input), inputTypeName: String(reflecting: DeveloperTextFeatureInput.self), deadline: Date().addingTimeInterval(30)))
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.output?.response, "Summarize: Real subject input")
        XCTAssertEqual(result.requestID, requestID)
    }
}
#endif
