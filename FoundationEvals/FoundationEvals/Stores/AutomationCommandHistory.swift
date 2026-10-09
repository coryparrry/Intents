#if os(macOS)
import Foundation
import IntentsAutomationCore

/// MCP IDs retain their session-long idempotency; native dialogs retain bounded status payloads.
struct AutomationCommandHistory {
    static let retentionLimit = 50
    private var nativeIDs: Set<UUID> = []
    private var unregisteredNativeIDs: Set<UUID> = []
    private var nativeOrder: [UUID] = []

    func isNative(_ id: UUID) -> Bool { nativeIDs.contains(id) }

    func canAdmit(_ id: UUID, nativeConfirmation: Bool, requests: [UUID: AutomationNativeCommandStatus]) -> Bool {
        if nativeConfirmation { return unregisteredNativeIDs.contains(id) }
        return !isNative(id) && requests.keys.filter { !isNative($0) }.count < Self.retentionLimit
    }

    mutating func admitted(_ id: UUID) { unregisteredNativeIDs.remove(id) }

    mutating func nativeRequestID(requests: inout [UUID: AutomationNativeCommandStatus], pending: UUID?, active: UUID?) -> UUID {
        if let pending { return pending }
        let absent = Set(nativeOrder.filter { requests[$0] == nil })
        unregisteredNativeIDs.subtract(absent)
        nativeOrder.removeAll { absent.contains($0) }
        var retained = nativeOrder.count
        for id in nativeOrder where retained >= Self.retentionLimit {
            guard id != pending, id != active, let request = requests[id],
                  ["completed", "cancelled", "invalidated", "failed"].contains(request.state) else { continue }
            requests[id] = nil
            retained -= 1
        }
        nativeOrder.removeAll { requests[$0] == nil }
        var id = UUID()
        while nativeIDs.contains(id) || requests[id] != nil { id = UUID() }
        // Keep only the UUID after payload expiry so MCP cannot adopt or replay this native request.
        nativeIDs.insert(id); unregisteredNativeIDs.insert(id); nativeOrder.append(id)
        return id
    }
}

extension AppAutomationStore {
    func nativeConfirmationRequestID() -> UUID { commandHistory.nativeRequestID(requests: &commandRequests, pending: pendingCommand, active: activeCommand) }
    /// A remote request can only queue native confirmation. It cannot mint approval.
    func requestCommand(id: UUID, digest: String, nativeConfirmation: Bool = false) throws -> AutomationNativeCommandStatus {
        guard !closing else { throw AutomationContractError.targetBusy }
        guard nativeConfirmation || !commandHistory.isNative(id) else { throw AutomationContractError.conflictingOperation }
        if let existing = commandRequests[id] {
            guard existing.digest == digest, existing.kind == nil else { throw AutomationContractError.conflictingOperation }
            return existing
        }
        guard pendingCommand == nil, commandHistory.canAdmit(id, nativeConfirmation: nativeConfirmation, requests: commandRequests) else { throw AutomationContractError.targetBusy }
        let preview = try previewCommand()
        guard preview.digest == digest else { throw AutomationContractError.conflictingOperation }
        let status = AutomationNativeCommandStatus(requestID: id, digest: digest, state: "awaitingApproval")
        commandRequests[id] = status; pendingCommand = id; commandHistory.admitted(id)
        message = "An execution request is ready. Review the selected app, inputs and effects, then confirm Run."
        return status
    }
}
#endif
