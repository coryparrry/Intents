#if os(macOS)
import Foundation

/// The server owns the whole enclosed attempt, including simulator preparation
/// and verified cleanup. The route still enforces its own plan/campaign deadline.
struct AutomationJavaScriptSessionTiming: Sendable {
    let operationTimeout: Duration
    let campaignDeadline: ContinuousClock.Instant?
    // Route drain (90s), owned simulator shutdown (60s), consumer/HTTP/server
    // finalization (up to 150s), and bounded persistence/inspection headroom.
    static let releaseAllowance: Duration = .seconds(360)

    static func workflow(wallClockSeconds: Int, allowBootAndInstall: Bool,
        campaignDeadline: ContinuousClock.Instant?) throws -> Self {
        guard wallClockSeconds > 0 else { throw AutomationContractError.invalidIdentity }
        // Inventory + release inspection (60s each), boot (60s), boot readiness
        // and install (120s each). These precede the route's plan clock.
        let setup: Duration = .seconds(allowBootAndInstall ? 420 : 120)
        return .init(operationTimeout: setup + .seconds(wallClockSeconds) + releaseAllowance,
                     campaignDeadline: campaignDeadline)
    }

    func operationDeadline(at now: ContinuousClock.Instant) -> ContinuousClock.Instant {
        let completeAttempt = now.advanced(by: operationTimeout)
        return min(completeAttempt, campaignDeadline?.advanced(by: Self.releaseAllowance) ?? completeAttempt)
    }

    func workerTimeout(automaticMetro: Bool) -> Duration {
        // Startup precedes the operation timer. Keep Node alive through the
        // complete operation and allow disposal to finish before its own timeout.
        // Readiness can reach its listener deadline before starting a bounded
        // HTTP bundle probe (another 120s for Metro, 5s for a leaf recipe).
        .seconds(automaticMetro ? 240 : 15) + operationTimeout + .seconds(180)
    }
}
#endif
