import Foundation

enum AutomationSidecarShutdown {
    // Actual pinned SDK close took 32.554s while stopping its runner. Retain a
    // finite response deadline; receiving an error never proves release.
    static func request(_ rpc: AutomationRPC) async throws -> AutomationJSON {
        try await rpc.request(.shutdown, params: .object(["protocolVersion": .number(1)]), timeout: .seconds(45))
    }
}
