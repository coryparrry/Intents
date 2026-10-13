import Foundation

struct AutomationSecretProgramCallback: Sendable {
    let handle: AutomationRPC.ReverseHandler
    func callAsFunction(_ method: String, _ input: AutomationJSON) async throws -> AutomationJSON { try await handle(method, input) }
}

/// Native-owned capability. It is never decoded from a request or capsule.
struct AutomationSecretProgramTransport: Sendable {
    let run: @Sendable (AutomationJSON, ContinuousClock.Instant, AutomationSecretProgramCallback) async throws -> AutomationJSON
    let closeAndDrain: @Sendable () async -> Bool
}
