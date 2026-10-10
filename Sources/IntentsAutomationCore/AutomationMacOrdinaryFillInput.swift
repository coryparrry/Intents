#if os(macOS)
import Foundation

/// Approved public text only; credential handles never enter this representation.
enum AutomationMacOrdinaryFillInput {
    static func validate(_ value: String) throws {
        guard value.utf8.count <= 65_536, value.utf16.count <= 16_384, !value.contains("\0") else {
            throw AutomationContractError.invalidIdentity
        }
    }
    static func frame(action: [String: AutomationJSON], nonce: String) throws -> Data {
        guard let value = action["value"]?.string, let instance = action["instance"],
              let x = action["x"], let y = action["y"] else { throw AutomationContractError.invalidIdentity }
        try validate(value)
        try AutomationMacHelperHandshake.validateNonce(nonce)
        let frame = AutomationJSON.object(["schemaVersion": .number(1), "kind": .string("ordinaryFill"),
            "nonce": .string(nonce), "applicationTarget": instance, "x": x, "y": y, "value": .string(value)])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var bytes = try encoder.encode(frame); bytes.append(10)
        try AutomationCommandGateInput.validatePrivateFrame(bytes)
        return bytes
    }
}
#endif
