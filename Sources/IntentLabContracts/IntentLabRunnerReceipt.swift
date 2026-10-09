import Foundation

/// Additive ownership evidence, separate from historical business-result envelopes.
/// A receipt records a running process; it never claims that process has stopped.
public struct IntentLabRunnerReceipt: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var invocationID: UUID
    public var nonce: String
    public var destinationIdentifier: String
    public var scenarioDigest: String
    public var testBundleIdentifier: String
    public var testProductSHA256: String
    public var processIdentifier: Int32
    public var kernelStartIdentity: String
    public var executableName: String

    public init(invocationID: UUID, nonce: String, destinationIdentifier: String,
                scenarioDigest: String, testBundleIdentifier: String, testProductSHA256: String,
                processIdentifier: Int32, kernelStartIdentity: String, executableName: String) {
        self.invocationID = invocationID; self.nonce = nonce; self.destinationIdentifier = destinationIdentifier
        self.scenarioDigest = scenarioDigest; self.testBundleIdentifier = testBundleIdentifier
        self.testProductSHA256 = testProductSHA256; self.processIdentifier = processIdentifier
        self.kernelStartIdentity = kernelStartIdentity; self.executableName = executableName
    }

    public func validate(invocationID: UUID, nonce: String, destinationIdentifier: String,
                         scenarioDigest: String, testBundleIdentifier: String,
                         testProductSHA256: String, executableName: String) throws {
        guard schemaVersion == 1, self.invocationID == invocationID,
              self.nonce == nonce, !nonce.isEmpty, nonce.utf8.count <= 256,
              self.destinationIdentifier == destinationIdentifier, !destinationIdentifier.isEmpty,
              self.scenarioDigest == scenarioDigest, Self.isDigest(scenarioDigest),
              self.testBundleIdentifier == testBundleIdentifier, !testBundleIdentifier.isEmpty,
              self.testProductSHA256 == testProductSHA256, Self.isDigest(testProductSHA256),
              processIdentifier > 0,
              kernelStartIdentity.range(of: #"^[0-9]{1,20}:[0-9]{1,6}$"#, options: .regularExpression) != nil,
              self.executableName == executableName, !executableName.isEmpty,
              executableName.utf8.count <= 256, !executableName.contains("/"), !executableName.contains("\0") else {
            throw CocoaError(.coderReadCorrupt)
        }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
    }
}
