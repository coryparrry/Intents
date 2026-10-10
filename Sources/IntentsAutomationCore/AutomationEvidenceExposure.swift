import Foundation

/// Native ownership of the campaign fence, never supplied by a worker or capsule.
public struct AutomationEvidenceExposureAuthority: Sendable {
    let supportRoot: URL
    private let fence: AutomationSecretEvidenceFence
    public init(supportRoot: URL) throws {
        guard supportRoot.isFileURL, try AutomationPath.canonical(supportRoot).path == supportRoot.path,
              try supportRoot.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw AutomationContractError.invalidIdentity
        }
        self.supportRoot = supportRoot
        fence = try .init(root: supportRoot.appendingPathComponent("secret-evidence"))
    }
    public func reserve(frozen: AutomationFrozenCase, attempts: [AutomationAttemptReport]) throws -> AutomationEvidenceExposure {
        try frozen.validate()
        guard attempts.count <= 1000, Set(attempts.map(\.attemptID)).count == attempts.count else {
            throw AutomationContractError.invalidIdentity
        }
        var permits: [AutomationSecretEvidencePermit] = [], runs: Set<String> = []
        for attempt in attempts {
            try AutomationRecordedEvidence.validate(report: attempt, plan: frozen.plan)
            for receipt in attempt.receipts where runs.insert(receipt.scope.runId).inserted {
                permits.append(try fence.reserve(receipt.scope))
            }
        }
        return try .init(frozen: frozen, attempts: attempts, permits: permits, supportRoot: supportRoot)
    }
}

/// Retain this opaque, non-Codable value through display or final publication.
/// Its shared locks prevent secret admission while those exact facts are exposed.
public final class AutomationEvidenceExposure: Sendable {
    let supportRoot: URL
    private let planSHA256: String
    private let reportSHA256: [String: String]
    private let permits: [AutomationSecretEvidencePermit]
    fileprivate init(frozen: AutomationFrozenCase, attempts: [AutomationAttemptReport], permits: [AutomationSecretEvidencePermit], supportRoot: URL) throws {
        self.supportRoot = supportRoot
        planSHA256 = try Self.digest(frozen.plan)
        reportSHA256 = try Dictionary(uniqueKeysWithValues: attempts.map { ($0.attemptID, try Self.digest($0)) })
        self.permits = permits
    }
    func validate(frozen: AutomationFrozenCase, attempts: [AutomationAttemptReport]) throws {
        try frozen.validate()
        guard try Self.digest(frozen.plan) == planSHA256, attempts.count == reportSHA256.count,
              Set(attempts.map(\.attemptID)).count == attempts.count else { throw AutomationContractError.conflictingOperation }
        for report in attempts {
            guard try reportSHA256[report.attemptID] == Self.digest(report) else { throw AutomationContractError.conflictingOperation }
        }
    }
    public func presentation(_ document: AutomationNativeEvidenceDocument) throws -> AutomationNativeEvidencePresentation {
        try document.validate()
        try validate(frozen: document.frozen, attempts: [document.report])
        return .init(document: document, exposure: self)
    }
    func validateSourceRoot(_ root: URL) throws {
        guard try AutomationPath.canonical(root).path == root.path, root == supportRoot else { throw AutomationContractError.conflictingOperation }
    }
    static func require(_ exposure: AutomationEvidenceExposure?, frozen: AutomationFrozenCase, attempts: [AutomationAttemptReport]) throws {
        if attempts.isEmpty { return }
        guard let exposure else { throw AutomationContractError.missingEvidence("Native evidence exposure permission is required") }
        try exposure.validate(frozen: frozen, attempts: attempts)
    }
    private static func digest<T: Encodable>(_ value: T) throws -> String {
        AutomationArtifactRegistry.digest(try AutomationFrozenCase.canonicalData(value))
    }
}

public struct AutomationNativeEvidencePresentation: Sendable, Identifiable {
    public let document: AutomationNativeEvidenceDocument
    private let exposure: AutomationEvidenceExposure
    public var id: String { document.id }
    fileprivate init(document: AutomationNativeEvidenceDocument, exposure: AutomationEvidenceExposure) {
        self.document = document; self.exposure = exposure
    }
}

public struct AutomationNativeEvidenceSnapshot: Sendable {
    public let presentations: [AutomationNativeEvidencePresentation]
    public var documents: [AutomationNativeEvidenceDocument] { presentations.map(\.document) }
}
