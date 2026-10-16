import Foundation
#if canImport(zlib)
import zlib
#endif

/// Bounded ZIP extraction for installed iOS products. No code is executed and
/// product bytes are not decrypted, rewritten, or re-signed.
public enum AutomationIPAArchive {
    public static let maximumArchiveBytes = 256 * 1024 * 1024
    static let maximumExpandedBytes = 1024 * 1024 * 1024
    struct Entry {
        let path: String; let directory: Bool; let mode: Int
        let method: Int; let checksum: Int; let expandedSize: Int; let payload: Range<Int>
    }
    public static func extract(_ input: URL, supportRoot: URL) throws -> URL {
        let bytes = try AutomationReadOnlyFile.read(input, maximumBytes: maximumArchiveBytes)
        let entries = try inspect(bytes)
        let root = supportRoot.appendingPathComponent("ImportedApplications").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try AutomationPath.canonical(root).path == root.path else { throw AutomationContractError.invalidIdentity }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: root) } }
        for entry in entries {
            try Task.checkCancellation()
            let content = try decode(entry, bytes: bytes)
            let destination = root.appendingPathComponent(entry.path)
            let parent = entry.directory ? destination : destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard try AutomationPath.canonical(parent).path == parent.path else { throw AutomationContractError.invalidIdentity }
            if !entry.directory {
                try content.write(to: destination, options: .withoutOverwriting)
                // Preserve executable bits, but never setuid/setgid or world-write.
                try FileManager.default.setAttributes([.posixPermissions: 0o600 | (entry.mode & 0o111)], ofItemAtPath: destination.path)
            }
        }
        let payload = root.appendingPathComponent("Payload")
        let apps = try FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }
        guard apps.count == 1 else { throw AutomationContractError.invalidPlan("The IPA must contain one main application in Payload.") }
        let assessment = try AutomationApplicationIntake.assess(apps[0])
        guard assessment.candidates.count == 1, assessment.candidates[0].app?.platform == "ios" else {
            throw AutomationContractError.invalidPlan("The IPA does not contain a valid iOS app product.")
        }
        struct Receipt: Codable { let sourceSHA256: String; let entries: Int; let expandedBytes: Int; let product: String }
        try AutomationDurableFile(url: root.appendingPathComponent("import.json"), maximumBytes: 16_384).write(JSONEncoder().encode(
            Receipt(sourceSHA256: AutomationArtifactRegistry.digest(bytes), entries: entries.count,
                    expandedBytes: entries.reduce(0) { $0 + $1.expandedSize }, product: "Payload/" + apps[0].lastPathComponent)))
        completed = true
        return apps[0]
    }
    static func inspect(_ bytes: Data) throws -> [Entry] {
        guard bytes.count >= 22, bytes.count <= maximumArchiveBytes else { throw invalid() }
        var end: Int?
        for offset in stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1) {
            if (try word(bytes, offset, 4)) == 0x06054b50, offset + 22 + (try word(bytes, offset + 20, 2)) == bytes.count { end = offset; break }
        }
        guard let end, (try word(bytes, end + 4, 2)) == 0, (try word(bytes, end + 6, 2)) == 0 else { throw invalid() }
        let count = (try word(bytes, end + 10, 2)), size = (try word(bytes, end + 12, 4)), start = (try word(bytes, end + 16, 4))
        guard count > 0, count <= 20_000, (try word(bytes, end + 8, 2)) == count, start + size == end else { throw invalid() }
        var cursor = start, total = 0, entries: [Entry] = [], paths = Set<String>(), files = Set<String>(), ranges: [Range<Int>] = []
        for _ in 0..<count {
            guard cursor + 46 <= end, (try word(bytes, cursor, 4)) == 0x02014b50 else { throw invalid() }
            let flags = (try word(bytes, cursor + 8, 2)), method = (try word(bytes, cursor + 10, 2))
            let checksum = (try word(bytes, cursor + 16, 4)), compressed = (try word(bytes, cursor + 20, 4)), expanded = (try word(bytes, cursor + 24, 4))
            let nameSize = (try word(bytes, cursor + 28, 2)), extraSize = (try word(bytes, cursor + 30, 2)), commentSize = (try word(bytes, cursor + 32, 2))
            let mode = (try word(bytes, cursor + 38, 4)) >> 16, local = (try word(bytes, cursor + 42, 4))
            guard flags & ~0x0808 == 0, [0, 8].contains(method), expanded <= 256 * 1024 * 1024,
                  cursor + 46 + nameSize + extraSize + commentSize <= end, (try word(bytes, cursor + 34, 2)) == 0,
                  nameSize > 0, nameSize <= 4096,
                  let name = String(data: bytes[(cursor + 46)..<(cursor + 46 + nameSize)], encoding: .utf8) else { throw invalid() }
            let directory = name.hasSuffix("/"), path = directory ? String(name.dropLast()) : name
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count <= 64, !path.contains("\\"), !path.contains("\0"),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  [0, directory ? 0o040000 : 0o100000].contains(mode & 0o170000),
                  !directory || (expanded == 0 && compressed <= 64) else { throw invalid() }
            let key = path.precomposedStringWithCanonicalMapping.lowercased()
            guard paths.insert(key).inserted else { throw invalid() }
            if !directory { files.insert(key) }
            total += expanded
            guard total <= maximumExpandedBytes, local + 30 <= start, (try word(bytes, local, 4)) == 0x04034b50,
                  (try word(bytes, local + 6, 2)) == flags, (try word(bytes, local + 8, 2)) == method,
                  (try word(bytes, local + 26, 2)) == nameSize else { throw invalid() }
            let payloadStart = local + 30 + nameSize + ((try word(bytes, local + 28, 2))), payloadEnd = payloadStart + compressed
            guard payloadEnd <= start, payloadStart >= local + 30 + nameSize,
                  bytes[(local + 30)..<(local + 30 + nameSize)] == bytes[(cursor + 46)..<(cursor + 46 + nameSize)] else { throw invalid() }
            var localEnd = payloadEnd
            if flags & 8 != 0 {
                let descriptor = payloadEnd + (((try word(bytes, payloadEnd, 4))) == 0x08074b50 ? 4 : 0)
                guard descriptor + 12 <= start, (try word(bytes, descriptor, 4)) == checksum,
                      (try word(bytes, descriptor + 4, 4)) == compressed, (try word(bytes, descriptor + 8, 4)) == expanded else { throw invalid() }
                localEnd = descriptor + 12
            } else {
                guard (try word(bytes, local + 14, 4)) == checksum, (try word(bytes, local + 18, 4)) == compressed,
                      (try word(bytes, local + 22, 4)) == expanded else { throw invalid() }
            }
            ranges.append(local..<localEnd)
            entries.append(.init(path: path, directory: directory, mode: mode, method: method, checksum: checksum, expandedSize: expanded, payload: payloadStart..<payloadEnd))
            cursor += 46 + nameSize + extraSize + commentSize
        }
        guard cursor == end else { throw invalid() }
        for path in paths {
            var parent = path
            while let slash = parent.lastIndex(of: "/") { parent = String(parent[..<slash]); if files.contains(parent) { throw invalid() } }
        }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        for index in sorted.indices.dropFirst() where sorted[index - 1].upperBound > sorted[index].lowerBound { throw invalid() }
        return entries
    }
    private static func decode(_ entry: Entry, bytes: Data) throws -> Data {
        #if canImport(zlib)
        let input = Data(bytes[entry.payload])
        var output: Data
        if entry.method == 0 { output = input }
        else {
            output = Data(count: entry.expandedSize + 1)
            var stream = z_stream()
            guard inflateInit2_(&stream, -15, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw invalid() }
            defer { inflateEnd(&stream) }
            try input.withUnsafeBytes { source in
                try output.withUnsafeMutableBytes { destination in
                    stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: UInt8.self).baseAddress)
                    stream.avail_in = UInt32(input.count)
                    stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress
                    stream.avail_out = UInt32(entry.expandedSize + 1)
                    guard inflate(&stream, Z_FINISH) == Z_STREAM_END, stream.avail_in == 0,
                          stream.total_out == entry.expandedSize else { throw invalid() }
                }
            }
            output.removeLast()
        }
        guard output.count == entry.expandedSize else { throw invalid() }
        let checksum = output.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, UInt32(output.count)) }
        guard checksum == entry.checksum else { throw invalid() }
        return output
        #else
        throw AutomationContractError.invalidPlan("IPA import requires the platform zlib module.")
        #endif
    }
    private static func word(_ bytes: Data, _ offset: Int, _ count: Int) throws -> Int {
        guard offset >= 0, offset + count <= bytes.count else { throw invalid() }
        return (0..<count).reduce(0) { $0 | (Int(bytes[offset + $1]) << ($1 * 8)) }
    }
    private static func invalid() -> AutomationContractError {
        .invalidPlan("The IPA is damaged or uses unsupported ZIP features. Imports require bounded, unencrypted ZIP entries with safe paths, ordinary files and verified checksums.")
    }
}
