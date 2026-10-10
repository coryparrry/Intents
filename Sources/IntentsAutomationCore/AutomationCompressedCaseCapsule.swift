import Foundation
#if canImport(zlib)
import zlib
#endif

/// Versioned raw-DEFLATE envelope. Logical records stay in memory; import never extracts paths.
enum AutomationCompressedCaseCapsule {
    static let maximumBytes = 48 * 1024 * 1024
    private static let magic = Data("INTCASE1".utf8)
    private static let headerSize = 80

    static func encode(manifest: AutomationCapsuleManifest, records: [String: Data]) throws -> Data {
        try AutomationCaseCapsule.validateManifest(manifest)
        guard Set(records.keys) == Set(manifest.files.map(\.path)) else { throw AutomationContractError.invalidIdentity }
        let manifestBytes = try AutomationFrozenCase.canonicalData(manifest)
        guard manifestBytes.count <= 128 * 1024 else { throw AutomationContractError.invalidIdentity }
        var payload = countBytes(manifestBytes.count)
        payload.append(manifestBytes)
        for entry in manifest.files {
            guard let bytes = records[entry.path], bytes.count == entry.size,
                  AutomationArtifactRegistry.digest(bytes) == entry.sha256 else { throw AutomationContractError.conflictingOperation }
            payload.append(bytes)
        }
        return try wrap(payload)
    }

    static func decode(_ bytes: Data) throws -> (AutomationCapsuleManifest, [String: Data]) {
        guard bytes.count >= headerSize, bytes.count <= maximumBytes,
              bytes.prefix(8) == magic else { throw AutomationContractError.invalidIdentity }
        let expandedSize = count(bytes, at: 8), compressedSize = count(bytes, at: 12)
        guard expandedSize >= 4, expandedSize <= maximumBytes, compressedSize > 0,
              compressedSize == bytes.count - headerSize else { throw AutomationContractError.invalidIdentity }
        let expectedDigest = String(decoding: bytes[16..<headerSize], as: UTF8.self)
        guard expectedDigest.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw AutomationContractError.invalidIdentity }
        let payload = try transform(Data(bytes.dropFirst(headerSize)), decoding: true, outputLimit: expandedSize + 1)
        guard payload.count == expandedSize, AutomationArtifactRegistry.digest(payload) == expectedDigest else { throw AutomationContractError.conflictingOperation }
        let manifestSize = count(payload, at: 0)
        guard manifestSize > 0, manifestSize <= 128 * 1024,
              manifestSize <= payload.count - 4 else { throw AutomationContractError.invalidIdentity }
        let manifest = try JSONDecoder().decode(AutomationCapsuleManifest.self, from: payload[4..<(4 + manifestSize)])
        try AutomationCaseCapsule.validateManifest(manifest)
        var offset = 4 + manifestSize
        guard manifest.files.reduce(offset, { $0 + $1.size }) == payload.count else { throw AutomationContractError.invalidIdentity }
        var records: [String: Data] = [:]
        for entry in manifest.files {
            records[entry.path] = payload[offset..<(offset + entry.size)]
            offset += entry.size
        }
        return (manifest, records)
    }

    // Internal to permit adversarial format tests without weakening the public importer.
    static func wrap(_ payload: Data) throws -> Data {
        guard payload.count >= 4, payload.count <= maximumBytes - 65_536 - headerSize else { throw AutomationContractError.invalidIdentity }
        let compressed = try transform(payload, decoding: false, outputLimit: payload.count + 65_536)
        var bytes = magic
        bytes.append(countBytes(payload.count)); bytes.append(countBytes(compressed.count))
        bytes.append(Data(AutomationArtifactRegistry.digest(payload).utf8)); bytes.append(compressed)
        return bytes
    }
    static func countBytes(_ value: Int) -> Data {
        let number = UInt32(value)
        return Data([UInt8((number >> 24) & 255), UInt8((number >> 16) & 255), UInt8((number >> 8) & 255), UInt8(number & 255)])
    }
    private static func count(_ bytes: Data, at offset: Int) -> Int {
        bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
    }
    private static func transform(_ input: Data, decoding: Bool, outputLimit: Int) throws -> Data {
        #if canImport(zlib)
        var output = Data(count: outputLimit)
        let written = try output.withUnsafeMutableBytes { destination in
            try input.withUnsafeBytes { source -> Int in
                var stream = z_stream()
                let status = decoding
                    ? inflateInit2_(&stream, -15, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
                    : deflateInit2_(&stream, 5, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
                guard status == Z_OK else { throw AutomationContractError.invalidIdentity }
                defer { if decoding { inflateEnd(&stream) } else { deflateEnd(&stream) } }
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: UInt8.self).baseAddress!)
                stream.avail_in = UInt32(input.count)
                stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress!
                stream.avail_out = UInt32(outputLimit)
                let result = decoding ? inflate(&stream, Z_FINISH) : deflate(&stream, Z_FINISH)
                // zlib's consumed-input count rejects concatenated streams and trailing data.
                guard result == Z_STREAM_END, stream.avail_in == 0,
                      stream.total_in == input.count else { throw AutomationContractError.invalidIdentity }
                return Int(stream.total_out)
            }
        }
        return output.prefix(written)
        #else
        throw AutomationContractError.invalidPlan("Compressed case capsules require the platform zlib module")
        #endif
    }
}
