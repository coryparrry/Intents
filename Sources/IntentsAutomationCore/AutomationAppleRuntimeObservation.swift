import Foundation

/// Receipt data is an observation only. It cannot create live capability authority.
struct AutomationAppleRuntimeObservation: Codable, Equatable, Sendable {
    let processOSVersion: String, processOSBuild: String, architecture: String
    let sdkPlatform: String, xcodeBuild: String, sdkBuild: String
    let frameworkPath: String, frameworkSHA256: String, frameworkUUID: String
    let frameworkCPUType: UInt32, frameworkCPUSubtype: UInt32

    static func parse(_ json: AutomationJSON) throws -> Self {
        guard let fields = json.object, Set(fields.keys) == ["processOSVersion", "processOSBuild", "architecture",
            "sdkPlatform", "xcodeBuild", "sdkBuild", "frameworkPath", "frameworkSHA256", "frameworkUUID",
            "frameworkCPUType", "frameworkCPUSubtype"] else { throw AutomationContractError.invalidIdentity }
        let value = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(json))
        guard [value.processOSVersion, value.processOSBuild, value.xcodeBuild, value.sdkBuild].allSatisfy({
            !$0.isEmpty && $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }), value.sdkPlatform == "macosx", value.frameworkPath.hasPrefix("/"), value.frameworkPath.utf8.count <= 4096,
            !value.frameworkPath.contains("\0"),
            [(value.frameworkSHA256, 64), (value.frameworkUUID, 32)].allSatisfy({ text, count in
                text.count == count && text.allSatisfy { $0.isASCII && "0123456789abcdef".contains($0) }
            }), (value.architecture == "arm64" && value.frameworkCPUType == 0x0100000c)
                || (value.architecture == "x86_64" && value.frameworkCPUType == 0x01000007) else {
            throw AutomationContractError.invalidIdentity
        }
        return value
    }
}

/// Bounded Mach-O identity parsing; a UUID identifies the loaded image, not resident code pages.
enum AutomationMachOLoadedImageIdentity {
    struct Image: Equatable, Sendable { let uuid: String; let cpu: UInt32; let subtype: UInt32 }
    static func images(in data: Data) throws -> [Image] {
        guard data.count >= 4, data.count <= 134_217_728 else { throw AutomationContractError.invalidIdentity }
        let magic = try word(data, 0, little: false)
        if magic == 0xcffaedfe { return [try thin(data)] }
        guard [UInt32(0xcafebabe), 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic) else {
            throw AutomationContractError.invalidIdentity
        }
        let little = magic == 0xbebafeca || magic == 0xbfbafeca
        let wide = magic == 0xcafebabf || magic == 0xbfbafeca
        let count = Int(try word(data, 4, little: little)), stride = wide ? 32 : 20
        guard count > 0, count <= 32, data.count >= 8 + count * stride else { throw AutomationContractError.invalidIdentity }
        var ranges: [Range<Int>] = [], result: [Image] = []
        for index in 0..<count {
            let base = 8 + index * stride
            let cpu = try word(data, base, little: little), subtype = try word(data, base + 4, little: little)
            let offset = wide ? try doubleWord(data, base + 8, little: little) : UInt64(try word(data, base + 8, little: little))
            let size = wide ? try doubleWord(data, base + 16, little: little) : UInt64(try word(data, base + 12, little: little))
            let align = try word(data, base + (wide ? 24 : 16), little: little)
            let reserved = wide ? try word(data, base + 28, little: little) : 0
            guard offset >= UInt64(8 + count * stride), size >= 32, offset <= UInt64(data.count),
                  size <= UInt64(data.count) - offset, align <= 30, offset % (UInt64(1) << align) == 0,
                  reserved == 0 else { throw AutomationContractError.invalidIdentity }
            let range = Int(offset)..<Int(offset + size)
            guard !ranges.contains(where: { $0.overlaps(range) }) else { throw AutomationContractError.invalidIdentity }
            let image = try thin(data.subdata(in: range))
            guard image.cpu == cpu, image.subtype == subtype,
                  !result.contains(where: { $0.cpu == cpu && $0.subtype == subtype }) else { throw AutomationContractError.invalidIdentity }
            ranges.append(range); result.append(image)
        }
        return result
    }
    private static func thin(_ data: Data) throws -> Image {
        guard data.count >= 32, try word(data, 0, little: true) == 0xfeedfacf else { throw AutomationContractError.invalidIdentity }
        let cpu = try word(data, 4, little: true), subtype = try word(data, 8, little: true)
        let count = Int(try word(data, 16, little: true)), size = Int(try word(data, 20, little: true))
        guard count > 0, count <= 4096, size >= count * 8, size <= 1_048_576, size <= data.count - 32 else {
            throw AutomationContractError.invalidIdentity
        }
        var offset = 32, uuid: String?
        for _ in 0..<count {
            guard offset <= 32 + size - 8 else { throw AutomationContractError.invalidIdentity }
            let cmd = try word(data, offset, little: true), length = Int(try word(data, offset + 4, little: true))
            guard length >= 8, length % 8 == 0, length <= 32 + size - offset else { throw AutomationContractError.invalidIdentity }
            if cmd == 0x1b {
                guard length == 24, uuid == nil else { throw AutomationContractError.invalidIdentity }
                uuid = data[(offset + 8)..<(offset + 24)].map { String(format: "%02x", $0) }.joined()
            }
            offset += length
        }
        guard offset == 32 + size, let uuid else { throw AutomationContractError.invalidIdentity }
        return .init(uuid: uuid, cpu: cpu, subtype: subtype)
    }
    private static func word(_ data: Data, _ offset: Int, little: Bool) throws -> UInt32 {
        guard offset >= 0, data.count >= 4, offset <= data.count - 4 else { throw AutomationContractError.invalidIdentity }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        return little ? UInt32(littleEndian: value) : UInt32(bigEndian: value)
    }
    private static func doubleWord(_ data: Data, _ offset: Int, little: Bool) throws -> UInt64 {
        guard offset >= 0, data.count >= 8, offset <= data.count - 8 else { throw AutomationContractError.invalidIdentity }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
        return little ? UInt64(littleEndian: value) : UInt64(bigEndian: value)
    }
}
