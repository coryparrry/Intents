import Foundation

/// Local format admission only. It does not establish signing, installation or device compatibility.
public enum AutomationPhysicalExecutable {
    static func validate(_ data: Data, fileType: UInt32 = 2) throws {
        guard fileType == 2 || fileType == 8 else { throw AutomationContractError.invalidIdentity }
        guard data.count >= 56 else { throw AutomationContractError.invalidIdentity }
        func integer(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset <= data.count - 4 else { throw AutomationContractError.invalidIdentity }
            return data[offset..<offset + 4].reversed().reduce(0) { ($0 << 8) | UInt32($1) }
        }
        // Thin little-endian 64-bit ARM executable. Simulator ARM64 is distinguished by the load command.
        guard try integer(0) == 0xfeedfacf, try integer(4) == 0x0100000c, try integer(12) == fileType else {
            throw AutomationContractError.invalidPlan("Select an ARM64 physical iOS executable")
        }
        let count = Int(try integer(16)), bytes = Int(try integer(20))
        guard (1...4096).contains(count), (24...1_048_576).contains(bytes), bytes <= data.count - 32 else {
            throw AutomationContractError.invalidIdentity
        }
        let end = 32 + bytes
        var offset = 32
        var platformCommands = 0
        for _ in 0..<count {
            guard offset <= end - 8 else { throw AutomationContractError.invalidIdentity }
            let command = try integer(offset), size = Int(try integer(offset + 4))
            guard size >= 8, size % 8 == 0, size <= end - offset else { throw AutomationContractError.invalidIdentity }
            if command == 0x32 { // LC_BUILD_VERSION
                guard size >= 24, try integer(offset + 8) == 2 else {
                    throw AutomationContractError.invalidPlan("Executable is not a physical iOS product")
                }
                let tools = Int(try integer(offset + 20))
                guard tools <= 64, size == 24 + tools * 8 else { throw AutomationContractError.invalidIdentity }
                platformCommands += 1
            } else if [UInt32(0x24), 0x25, 0x2f, 0x30].contains(command) {
                throw AutomationContractError.invalidPlan("Legacy or conflicting executable platform is unqualified")
            }
            offset += size
        }
        guard offset == end, platformCommands == 1 else { throw AutomationContractError.invalidIdentity }
    }

    public static func validateTarget(_ target: TargetIdentity) throws {
        guard target.kind == .physical,
              target.id.range(of: #"\A(?:[A-Fa-f0-9]{40}|[A-Fa-f0-9]{8}-[A-Fa-f0-9]{16}|[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12})\z"#,
                              options: .regularExpression) != nil else { throw AutomationContractError.invalidIdentity }
    }
}
