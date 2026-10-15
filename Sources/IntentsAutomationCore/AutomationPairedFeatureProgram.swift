import Foundation

/// Public registered feature identity and subject input only. Expected answers
/// live in the case's independent requirements, never in this payload.
public struct AutomationPairedFeatureProgram: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case execute, readResponse }
    public var mode: Mode
    public var runnerID: UUID
    public var registrationDigest: String
    public var appVersion: String
    public var featureID: String
    public var featureVersion: String
    public var instructions: String
    public var prompt: String
    public init(mode: Mode = .execute, runnerID: UUID, registrationDigest: String, appVersion: String,
                featureID: String, featureVersion: String, instructions: String, prompt: String) {
        self.mode = mode; self.runnerID = runnerID; self.registrationDigest = registrationDigest; self.appVersion = appVersion
        self.featureID = featureID; self.featureVersion = featureVersion; self.instructions = instructions; self.prompt = prompt
    }
    func validate(segment: AutomationSegment, target: TargetIdentity) throws {
        guard target.kind == .pairedRunner, target.id == runnerID.uuidString, segment.kind == .pairedFeature,
              registrationDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              [appVersion, featureID, featureVersion].allSatisfy({ !$0.isEmpty && $0.utf16.count <= 256 && !$0.contains("\0") }),
              instructions.utf16.count <= 32768, !prompt.isEmpty, prompt.utf16.count <= 32768,
              segment.inputs.isEmpty, segment.inputBindings?.isEmpty != false, segment.attemptTextBindings?.isEmpty != false,
              segment.lifecycle == .persistedStateAcrossSegments,
              (mode == .execute && segment.phase == .subject) || (mode == .readResponse && segment.phase == .observe && segment.effects == [.observe]) else {
            throw AutomationContractError.invalidPlan("Paired feature scope does not match its registered runner and phase")
        }
    }
    public var executionIdentity: Self { var value = self; value.mode = .execute; return value }
}

public struct AutomationPairedFeatureReply: Sendable {
    public var requestID: UUID
    public var response: String?
    public var failure: String?
    public init(requestID: UUID, response: String?, failure: String? = nil) { self.requestID = requestID; self.response = response; self.failure = failure }
}
public protocol AutomationPairedFeatureClient: Sendable {
    func validate(program: AutomationPairedFeatureProgram, app: AppIdentity) async throws
    func execute(program: AutomationPairedFeatureProgram, app: AppIdentity, requestID: UUID, runID: UUID, timeout: Duration) async throws -> AutomationPairedFeatureReply
}
