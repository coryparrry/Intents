import Foundation

/// Fixed diagnostic facts never weaken release proof or import execution authority.
struct AutomationSidecarReleaseDiagnostics: Codable, Equatable, Sendable {
    let scope: AutomationScope
    let shutdownReceived: Bool
    let shutdownResourcesReleased: Bool?
    let shutdownCleanupReason: String?
    let shutdownErrorType: String?
    let shutdownErrorCode: String?
    let processStopped: Bool
    let deviceReleased: Bool
    let subjectInspectionUnreleased: Bool
    let commandsDrained: Bool

    init(scope: AutomationScope, shutdown: AutomationJSON?, errorType: String?, errorCode: String? = nil, stopped: Bool,
         deviceReleased: Bool, subjectInspectionUnreleased: Bool, drained: Bool) {
        self.scope = scope; shutdownReceived = shutdown != nil
        if case .bool(let value) = shutdown?.object?["resourcesReleased"] { shutdownResourcesReleased = value }
        else { shutdownResourcesReleased = nil }
        let allowed = ["complete", "pendingWork", "inventoryUnreleased", "sessionUnreleased", "sessionReleaseError", "acquisitionUnknown"]
        if case .string(let reason) = shutdown?.object?["cleanupReason"] {
            shutdownCleanupReason = allowed.contains(reason) ? reason : "unknown"
        } else { shutdownCleanupReason = nil }
        shutdownErrorType = errorType.map { String($0.prefix(256)) }
        let errorCodes = ["invalidFrame", "requestLimit", "disconnected", "timedOut", "dispatchedOutcomeUnknown", "cancelled", "remote", "other"]
        shutdownErrorCode = errorCode.map { errorCodes.contains($0) ? $0 : "unknown" }
        processStopped = stopped; self.deviceReleased = deviceReleased
        self.subjectInspectionUnreleased = subjectInspectionUnreleased; commandsDrained = drained
    }
    static func errorCode(_ error: any Error) -> String {
        guard let rpc = error as? AutomationRPCError else { return "other" }
        switch rpc {
        case .invalidFrame: return "invalidFrame"
        case .requestLimit: return "requestLimit"
        case .disconnected: return "disconnected"
        case .timedOut: return "timedOut"
        case .dispatchedOutcomeUnknown: return "dispatchedOutcomeUnknown"
        case .cancelled: return "cancelled"
        case .remote: return "remote"
        }
    }
}
