import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Version-one product manifest, shared with the engineering qualification command.
public enum AutomationProductDigest {
    public static func compute(bundle: URL, version: Int?) throws -> String {
        AutomationArtifactRegistry.digest(try manifestData(bundle: bundle, version: version))
    }
    public static func manifestData(bundle: URL, version: Int?) throws -> Data {
        guard version == nil || version == 1 || version == 2 else { throw AutomationContractError.invalidIdentity }
        return try manifestData(bundle: bundle, fileHashed: nil, linkedProduct: version == 2)
    }
    /// Product-only reader; capsule, case and host/session readers retain their no-link policy.
    public static func readFile(bundle: URL, relativePath: String, maximumBytes: Int, version: Int?, expectedDigest: String? = nil) throws -> Data {
        try readFile(bundle: bundle, relativePath: relativePath, maximumBytes: maximumBytes, version: version, expectedDigest: expectedDigest, stage: nil)
    }
    enum ReadStage { case beforeRead, afterRead }
    static func readFile(bundle: URL, relativePath: String, maximumBytes: Int, version: Int?, expectedDigest: String?, stage: ((ReadStage) throws -> Void)?) throws -> Data {
        guard version == nil || version == 1 || version == 2 else { throw AutomationContractError.invalidIdentity }
        guard version == 2 else {
            if let expectedDigest {
                return try readLegacyFile(bundle: bundle, relativePath: relativePath, maximumBytes: maximumBytes,
                    expectedDigest: expectedDigest, stage: stage)
            }
            return try AutomationReadOnlyFile.read(root: bundle, relativePath: relativePath, maximumBytes: maximumBytes)
        }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), !relativePath.contains("\\"), !relativePath.contains("\0") else { throw AutomationContractError.invalidIdentity }
        let root = try AutomationPath.canonical(bundle), before = try manifestData(bundle: root, version: version)
        if let expectedDigest { guard AutomationArtifactRegistry.digest(before) == expectedDigest else { throw AutomationContractError.conflictingOperation } }
        guard let manifest = try JSONSerialization.jsonObject(with: before) as? [String: Any],
              let files = manifest["files"] as? [[String: Any]], let links = manifest["links"] as? [[String: Any]] else { throw AutomationContractError.invalidIdentity }
        var resolved = parts.map(String.init)
        // Link targets in this validated manifest are canonical in-root paths.
        for _ in 0..<64 {
            var substituted = false
            for index in resolved.indices {
                let prefix = resolved.prefix(index + 1).joined(separator: "/")
                if let link = links.first(where: { $0["path"] as? String == prefix }), let target = link["target"] as? String {
                    resolved = target.split(separator: "/").map(String.init) + resolved.dropFirst(index + 1)
                    substituted = true; break
                }
            }
            if !substituted { break }
        }
        let expectedPath = resolved.joined(separator: "/")
        guard let record = files.first(where: { $0["path"] as? String == expectedPath }),
              let count = record["bytes"] as? Int, let digest = record["sha256"] as? String else { throw AutomationContractError.invalidIdentity }
        try stage?(.beforeRead)
        let file = try AutomationPath.canonical(root.appendingPathComponent(relativePath))
        guard file.path == root.appendingPathComponent(expectedPath).path else { throw AutomationContractError.conflictingOperation }
        let data = try AutomationReadOnlyFile.read(root: root, relativePath: String(file.path.dropFirst(root.path.count + 1)), maximumBytes: maximumBytes)
        try stage?(.afterRead)
        guard data.count == count, AutomationArtifactRegistry.digest(data) == digest else { throw AutomationContractError.conflictingOperation }
        guard before == (try manifestData(bundle: root, version: version)) else { throw AutomationContractError.conflictingOperation }
        return data
    }
    private static func readLegacyFile(bundle: URL, relativePath: String, maximumBytes: Int,
                                       expectedDigest: String, stage: ((ReadStage) throws -> Void)?) throws -> Data {
        let root = try AutomationPath.canonical(bundle), before = try manifestData(bundle: root, version: 1)
        guard AutomationArtifactRegistry.digest(before) == expectedDigest else { throw AutomationContractError.conflictingOperation }
        guard let records = try JSONSerialization.jsonObject(with: before) as? [[String: Any]],
              let record = records.first(where: { $0["path"] as? String == relativePath }),
              let count = record["bytes"] as? Int, let digest = record["sha256"] as? String else {
            throw AutomationContractError.invalidIdentity
        }
        try stage?(.beforeRead)
        let data = try AutomationReadOnlyFile.read(root: root, relativePath: relativePath, maximumBytes: maximumBytes)
        try stage?(.afterRead)
        guard data.count == count, AutomationArtifactRegistry.digest(data) == digest,
              before == (try manifestData(bundle: root, version: 1)) else { throw AutomationContractError.conflictingOperation }
        return data
    }
    public static func compute(bundle: URL) throws -> String {
        AutomationArtifactRegistry.digest(try manifestData(bundle: bundle))
    }
    public static func manifestData(bundle: URL) throws -> Data {
        try manifestData(bundle: bundle, fileHashed: nil)
    }
    static func manifestData(bundle: URL, fileHashed: ((String) throws -> Void)?, linkedProduct: Bool = false) throws -> Data {
        let root = try AutomationPath.canonical(bundle)
        var identities = [root.path: try identity(at: root.path)]
        var failed = false
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            errorHandler: { _, _ in failed = true; return false }) else { throw AutomationContractError.invalidIdentity }
        var records: [(String, Int, String)] = [], total = 0, entries = 0
        var links: [(String, String, String, String)] = []
        for case let file as URL in enumerator {
            entries += 1
            guard entries <= 100_000, enumerator.level <= 64, file.path.hasPrefix(root.path + "/") else { throw AutomationContractError.invalidIdentity }
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                guard linkedProduct else { throw AutomationContractError.invalidIdentity }
                let resolved = try internalLink(file, root: root, identities: &identities)
                links.append((String(file.path.dropFirst(root.path.count + 1)), resolved.destination, resolved.target, resolved.kind))
                continue
            }
            if values.isDirectory == true {
                let current = try identity(at: file.path)
                if linkedProduct, let prior = identities[file.path], prior != current { throw AutomationContractError.conflictingOperation }
                identities[file.path] = current; continue
            }
            let fd = linkedProduct ? try openProductFile(file, root: root) : open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw AutomationContractError.invalidIdentity }
            var before = stat()
            guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                  before.st_size >= 0, before.st_size <= 536_870_912 else { close(fd); throw AutomationContractError.invalidIdentity }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var hash = SHA256(), count = 0
            while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
                count += bytes.count; total += bytes.count
                guard count <= 536_870_912, total <= 4_294_967_296 else { throw AutomationContractError.invalidIdentity }
                hash.update(data: bytes)
            }
            var after = stat()
            guard fstat(fd, &after) == 0, count == before.st_size, after.st_size == before.st_size,
                  after.st_ino == before.st_ino else { throw AutomationContractError.conflictingOperation }
            #if canImport(Darwin)
            guard after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
                  after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else { throw AutomationContractError.conflictingOperation }
            #else
            guard after.st_mtim.tv_sec == before.st_mtim.tv_sec, after.st_mtim.tv_nsec == before.st_mtim.tv_nsec,
                  after.st_ctim.tv_sec == before.st_ctim.tv_sec, after.st_ctim.tv_nsec == before.st_ctim.tv_nsec else { throw AutomationContractError.conflictingOperation }
            #endif
            records.append((String(file.path.dropFirst(root.path.count + 1)), count, hash.finalize().map { String(format: "%02x", $0) }.joined()))
            let current = Fingerprint(before)
            if linkedProduct, let prior = identities[file.path], prior != current { throw AutomationContractError.conflictingOperation }
            identities[file.path] = current
            try fileHashed?(file.lastPathComponent)
        }
        guard !failed else { throw AutomationContractError.invalidIdentity }
        // An earlier hashed file or its parent can be atomically swapped while another file is read.
        for (path, expected) in identities {
            guard try identity(at: path, allowLink: linkedProduct) == expected else { throw AutomationContractError.conflictingOperation }
        }
        records.sort { $0.0.unicodeScalars.lexicographicallyPrecedes($1.0.unicodeScalars) }
        let json = try records.map { path, count, digest in
            "{\"bytes\":\(count),\"path\":\(try asciiJSON(path)),\"sha256\":\(try asciiJSON(digest))}"
        }.joined(separator: ",")
        guard linkedProduct else { return Data(("[" + json + "]").utf8) }
        links.sort { $0.0.unicodeScalars.lexicographicallyPrecedes($1.0.unicodeScalars) }
        let linkJSON = try links.map { path, destination, target, kind in
            "{\"destination\":\(try asciiJSON(destination)),\"kind\":\(try asciiJSON(kind)),\"path\":\(try asciiJSON(path)),\"target\":\(try asciiJSON(target))}"
        }.joined(separator: ",")
        return Data(("{\"files\":[" + json + "],\"links\":[" + linkJSON + "],\"schemaVersion\":2}").utf8)
    }
    private struct Fingerprint: Equatable {
        var device: UInt64, inode: UInt64, size: Int64, mode: UInt32
        var modifiedSeconds: Int64, modifiedNanos: Int64, changedSeconds: Int64, changedNanos: Int64
        init(_ value: stat) {
            device = UInt64(truncatingIfNeeded: value.st_dev); inode = UInt64(value.st_ino)
            size = Int64(value.st_size); mode = UInt32(value.st_mode)
            #if canImport(Darwin)
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
            changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanos = Int64(value.st_ctimespec.tv_nsec)
            #else
            modifiedSeconds = Int64(value.st_mtim.tv_sec); modifiedNanos = Int64(value.st_mtim.tv_nsec)
            changedSeconds = Int64(value.st_ctim.tv_sec); changedNanos = Int64(value.st_ctim.tv_nsec)
            #endif
        }
    }
    private static func identity(at path: String, allowLink: Bool = false) throws -> Fingerprint {
        var info = stat()
        guard lstat(path, &info) == 0, (allowLink ? [S_IFREG, S_IFDIR, S_IFLNK] : [S_IFREG, S_IFDIR]).contains(info.st_mode & S_IFMT) else { throw AutomationContractError.invalidIdentity }
        return Fingerprint(info)
    }
    /// Resolve relative links one component at a time, never traversing outside the root.
    private static func internalLink(_ link: URL, root: URL, identities: inout [String: Fingerprint]) throws -> (destination: String, target: String, kind: String) {
        let original = try identity(at: link.path, allowLink: true)
        if let prior = identities[link.path], prior != original { throw AutomationContractError.conflictingOperation }
        identities[link.path] = original
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        var components = Array(link.deletingLastPathComponent().path.dropFirst(root.path.count).split(separator: "/").map(String.init))
        var pending = destination.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !destination.hasPrefix("/"), destination.utf8.count <= 4096, !destination.isEmpty else { throw AutomationContractError.invalidIdentity }
        var steps = 0, followed = 0
        while !pending.isEmpty {
            steps += 1; guard steps <= 512, components.count <= 64 else { throw AutomationContractError.invalidIdentity }
            let component = pending.removeFirst()
            if component.isEmpty || component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else { throw AutomationContractError.invalidIdentity }
                components.removeLast(); continue
            }
            components.append(component)
            let path = root.appendingPathComponent(components.joined(separator: "/")).path
            let fingerprint = try identity(at: path, allowLink: true)
            if let prior = identities[path], prior != fingerprint { throw AutomationContractError.conflictingOperation }
            identities[path] = fingerprint
            if fingerprint.mode & UInt32(S_IFMT) == UInt32(S_IFLNK) {
                followed += 1; guard followed <= 64 else { throw AutomationContractError.invalidIdentity }
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: path)
                guard !target.hasPrefix("/"), !target.isEmpty, target.utf8.count <= 4096 else { throw AutomationContractError.invalidIdentity }
                components.removeLast(); pending = target.split(separator: "/", omittingEmptySubsequences: false).map(String.init) + pending
            } else if !pending.isEmpty, fingerprint.mode & UInt32(S_IFMT) != UInt32(S_IFDIR) { throw AutomationContractError.invalidIdentity }
        }
        let path = root.appendingPathComponent(components.joined(separator: "/")).path
        let target = try identity(at: path)
        if let prior = identities[path], prior != target { throw AutomationContractError.conflictingOperation }
        identities[path] = target
        return (destination, components.joined(separator: "/"), target.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) ? "directory" : "file")
    }
    private static func openProductFile(_ file: URL, root: URL) throws -> Int32 {
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw AutomationContractError.invalidIdentity }
        defer { close(directory) }
        var components = file.path.dropFirst(root.path.count + 1).split(separator: "/").map(String.init)
        guard let name = components.popLast() else { throw AutomationContractError.invalidIdentity }
        for component in components {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw AutomationContractError.invalidIdentity }
            close(directory); directory = next
        }
        return openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    }
    private static func asciiJSON(_ text: String) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let quoted = String(decoding: try encoder.encode(text), as: UTF8.self)
        return quoted.utf16.map { $0 > 127 ? String(format: "\\u%04x", $0) : String(UnicodeScalar($0)!) }.joined()
    }
}
