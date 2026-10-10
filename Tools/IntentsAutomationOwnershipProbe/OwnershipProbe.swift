import Foundation
import IntentsAutomationCore

/// Developer-only cross-process recovery fixture. No app/device commands are available.
@main struct OwnershipProbe {
    static func main() async throws {
        guard (2...3).contains(CommandLine.arguments.count), CommandLine.arguments.count == 2 || CommandLine.arguments[2] == "physical" else { throw AutomationContractError.invalidIdentity }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let manager = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("leases.json"))
        let physical = CommandLine.arguments.count == 3
        let lease = try await manager.acquire(runID: "old", target: .init(id: "device", kind: physical ? .physical : .simulator), control: physical ? .system : .ui)
        let dispatch = AutomationDeviceLeaseManager.Dispatch(scope: .init(runID: "old", attemptID: "attempt", segmentID: "subject", leaseGeneration: lease.generation),
            operationID: "subject", payloadDigest: String(repeating: "a", count: 64))
        let journal = try AutomationJournal(url: root.appendingPathComponent("journal.json"))
        _ = try await journal.begin(operationID: dispatch.operationID, digest: dispatch.payloadDigest)
        try await manager.recordDispatch(dispatch, lease: lease)
        try FileHandle.standardOutput.write(contentsOf: Data("1".utf8))
        _ = try FileHandle.standardInput.read(upToCount: 1)
        // Leave the persisted lease and dispatch intact to exercise recovery after exit.
    }
}
