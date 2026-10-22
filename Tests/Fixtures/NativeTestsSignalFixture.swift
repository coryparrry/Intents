import Darwin
import Foundation

// Compiled by the CLI regression with the production signal scope and command owner.
struct MacIntentTestingError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@main
struct NativeTestsSignalFixture {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let log = try FileHandle(forWritingTo: root.appendingPathComponent("command.log"))
        defer { try? log.close() }
        let command = MacIntentOwnedCommand()
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        var cancelled = false
        do {
            try await NativeTestsSignals.whileRunning(cancel: { command.cancel() }) {
                _ = try await command.execute(executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "printf '%s' \"$$\" > child.pid; IFS= read -r ignored < child-input"],
                    directory: root, environment: ProcessInfo.processInfo.environment,
                    log: log, timeout: 30)
            }
        } catch is CancellationError {
            cancelled = true
        }
        // Both pre-existing ignored dispositions must survive the signal scope.
        raise(SIGINT)
        raise(SIGTERM)
        print(cancelled && !command.hasUnresolvedResources ? "cancelled; restored; released" : "unexpected completion")
        exit(cancelled && !command.hasUnresolvedResources ? 1 : 2)
    }
}
