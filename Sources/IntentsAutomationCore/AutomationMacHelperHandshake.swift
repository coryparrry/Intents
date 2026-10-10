import Foundation

/// Startup protocol only; the parent must independently own the child and pin its gated ABI.
public enum AutomationMacHelperHandshake {
    struct Message: Codable, Equatable {
        var schemaVersion = 1
        var kind: String
        var nonce: String
        var identity: AutomationProcessIdentity
    }
    public static func validateNonce(_ nonce: String) throws {
        guard UUID(uuidString: nonce)?.uuidString.lowercased() == nonce else { throw AutomationContractError.invalidIdentity }
    }
    public static func ready(nonce: String, identity: AutomationProcessIdentity) throws -> Data {
        try frame(.init(kind: "ready", nonce: nonce, identity: identity))
    }
    public static func acknowledgement(ready: Data, nonce: String, ownedChild: AutomationProcessIdentity) throws -> Data {
        let message = try decode(ready, kind: "ready", nonce: nonce, identity: ownedChild)
        return try frame(.init(kind: "ack", nonce: message.nonce, identity: message.identity))
    }
    public static func validateAcknowledgement(_ data: Data, nonce: String, identity: AutomationProcessIdentity) throws {
        _ = try decode(data, kind: "ack", nonce: nonce, identity: identity)
    }
    private static func decode(_ data: Data, kind: String, nonce: String, identity: AutomationProcessIdentity) throws -> Message {
        guard data.count <= 4096, data.last == 10 else { throw AutomationContractError.invalidIdentity }
        let message = try JSONDecoder().decode(Message.self, from: Data(data.dropLast()))
        guard message.schemaVersion == 1, message.kind == kind, message.nonce == nonce, message.identity == identity,
              try frame(message) == data else { throw AutomationContractError.invalidIdentity }
        return message
    }
    private static func frame(_ message: Message) throws -> Data {
        try validateNonce(message.nonce)
        let parts = message.identity.startIdentity.split(separator: ":", omittingEmptySubsequences: false)
        guard message.identity.pid > 0, parts.count == 2, let seconds = UInt64(parts[0]), seconds > 0,
              String(seconds) == parts[0], let micros = UInt32(parts[1]), micros <= 999_999,
              String(micros) == parts[1] else { throw AutomationContractError.invalidIdentity }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(message); data.append(10)
        guard data.count <= 4096 else { throw AutomationContractError.invalidIdentity }
        return data
    }
}
