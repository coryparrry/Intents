#if os(macOS) || os(Linux)
import Foundation

/// Bounded simulator cleanup; retained diagnostics never grant release authority.
enum AutomationSimulatorTermination {
    struct Record: Codable {
        let bundleID: String
        let completed: Bool
        let accepted: Bool
        let exitStatus: Int32
        let stdout: Data
        let stderr: Data
        let logsTruncated: Bool
        let error: String?
    }

    static func stop(
        bundleIDs: [String], diagnosticRoot: URL,
        run: @Sendable (String, Duration) async throws -> AutomationOwnedCommand.Result,
        retainedLogs: @Sendable () async -> AutomationOwnedCommand.Result
    ) async -> Bool {
        var records: [Record] = []
        var stopped = true
        for bundleID in bundleIDs {
            let result: AutomationOwnedCommand.Result
            let error: String?
            do {
                // Match the release inspector's budget: simctl can take longer
                // than fifteen seconds on a loaded simulator after XCTest exits.
                result = try await run(bundleID, .seconds(60))
                error = nil
            } catch let failure {
                result = await retainedLogs()
                error = String(decoding: String(describing: failure).utf8.prefix(4096), as: UTF8.self)
            }
            let text = String(decoding: result.stdout + result.stderr, as: UTF8.self)
            let accepted = error == nil && !result.logsTruncated &&
                AutomationXCUITestRouteDriver.terminationSucceeded(exitStatus: result.exitStatus, output: text)
            stopped = stopped && accepted
            records.append(Record(bundleID: bundleID, completed: error == nil, accepted: accepted,
                exitStatus: result.exitStatus, stdout: Data(result.stdout.prefix(8192)),
                stderr: Data(result.stderr.prefix(8192)),
                logsTruncated: result.logsTruncated || result.stdout.count > 8192 || result.stderr.count > 8192,
                error: error))
            do {
                let data = try JSONEncoder().encode(records)
                let file = try AutomationDurableFile(url: diagnosticRoot.appendingPathComponent("simulator-release.json"), maximumBytes: 65_536)
                try file.withLock { try file.write(data) }
            } catch { /* Failed diagnostics must not change release verification. */ }
        }
        return stopped
    }
}
#endif
