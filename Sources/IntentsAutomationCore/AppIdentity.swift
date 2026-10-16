import Foundation

public struct AppIdentity: Codable, Equatable, Sendable {
    public var logicalID: String
    public var bundleID: String
    public var canonicalBundlePath: String?
    public var owningModule: String?
    public var productDigest: String?
    /// Absent on frozen v1 products. New linked Mac bundles explicitly use v2.
    public var productDigestVersion: Int? = nil
    public var codeDirectoryIdentity: String?
    public var configuration: String?
    public var architecture: String?
    public var platform: String
    public var sourceManifestDigest: String?
    public var sourceSyntaxIndexDigest: String? = nil
    /// Actual approved served JavaScript bytes and their native/source bindings.
    public var servedJavaScriptDigest: String? = nil
    public var provenanceStrength: String
    public init(logicalID: String, bundleID: String, platform: String, productDigest: String? = nil) {
        self.logicalID = logicalID; self.bundleID = bundleID; self.platform = platform
        self.productDigest = productDigest; self.provenanceStrength = productDigest == nil ? "installedIdentity" : "productBytes"
    }
}

public struct TargetIdentity: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case simulator, physical, nativeMac, pairedRunner }
    public var id: String
    public var kind: Kind
    public var osBuild: String?
    public var transport: String?
    public var toolchain: String?
    public var loginSession: String?
    /// CoreDevice UUID resolved at discovery; `id` remains the Xcode destination UDID.
    public var physicalDeviceIdentifier: String?
    public init(id: String, kind: Kind, loginSession: String? = nil) {
        self.id = id; self.kind = kind; self.loginSession = loginSession
    }
    public var leaseKey: String {
        if kind == .pairedRunner { return "paired:\(id)" }
        if kind == .nativeMac { return "mac:\(loginSession ?? "unknown")" }
        guard kind == .physical else { return "ios:\(id)" }
        // Preserve keys of pre-resolution campaigns so their original owner can release them.
        guard let identifier = physicalDeviceIdentifier else { return "ios:\(id)" }
        return "ios:\(UUID(uuidString: identifier)?.uuidString ?? identifier)"
    }
}

public struct CapabilityProfile: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case unknown, available, unavailable, consentRequired }
    public struct Record: Codable, Equatable, Sendable {
        public var state: State
        public var reason: String
        public var probeVersion: String
        public var evidence: [String]
        public init(state: State, reason: String, probeVersion: String, evidence: [String]) {
            self.state = state; self.reason = reason; self.probeVersion = probeVersion; self.evidence = evidence
        }
    }
    public var records: [String: Record]
    public init(records: [String: Record] = [:]) { self.records = records }
    public func supports(_ capabilities: [String]) -> Bool { capabilities.allSatisfy { records[$0]?.state == .available } }
}
