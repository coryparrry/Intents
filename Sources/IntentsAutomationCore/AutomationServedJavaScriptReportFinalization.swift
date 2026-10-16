#if os(macOS)
import Foundation

/// Finalize the server before publishing immutable attempt evidence. No prior
/// passed report needs overwriting when bytes change or release cannot be proved.
enum AutomationServedJavaScriptReportFinalization {
    static func finish(_ report: AutomationAttemptReport, operation: @escaping @Sendable () async throws -> Void) async -> AutomationAttemptReport {
        var result = report
        do { try await operation() }
        catch {
            let uncertain = error as? AutomationContractError == .terminationUnverified
            result.resourcesReleased = false
            result.result.summary = uncertain ? .unresolved : .infrastructureFailed
            result.result.assessed = false; result.result.evidenceComplete = false
        }
        return result
    }
}
#endif
