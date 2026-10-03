import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ProductionCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer(); try value.encode(Int64((date.timeIntervalSince1970*1000).rounded()))
        }
        return try encoder.encode(value)
    }
    static func legacyEncode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970; return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func fileDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 65_536), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func stableID(_ value: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                           bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try encode(value).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }; try handle.synchronize()
    }
    public static func fileSize(_ url: URL) throws -> Int {
        // URL resource values are cached; live worker output must be measured from the filesystem.
        guard let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else { throw ProductionFailure.integrity("Cannot read file size.") }
        return size.intValue
    }
    public static func read<T: Decodable>(_ type: T.Type, from url: URL, maximumBytes: Int = 70_000_000) throws -> T {
        let size = try fileSize(url)
        guard size <= maximumBytes else { throw ProductionFailure.invalid("Stored record exceeds its size limit.") }
        return try decode(type, Data(contentsOf: url))
    }
    static func validateDigest(_ value: String) throws {
        guard value.count == 64, value.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw ProductionFailure.invalid("Invalid content revision.")
        }
    }
}

/// File-system transactions coordinate app and CLI processes. Storage must support flock and atomic rename.
public final class ProductionStorage: @unchecked Sendable {
    public let root: URL
    public init(root: URL) throws {
        self.root = root.standardizedFileURL
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        for folder in ["Datasets", "Jobs", "Workers", "Reviews", "Schedules"] {
            try FileManager.default.createDirectory(at: self.root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
    }
    func transaction<T>(_ operation: () throws -> T) throws -> T {
        let path = root.appendingPathComponent(".store.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw ProductionFailure.unavailable("Cannot open storage transaction lock.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw ProductionFailure.unavailable("Cannot lock production storage.") }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }
    public func datasetDirectory(_ revision: String) throws -> URL {
        try ProductionCodec.validateDigest(revision)
        return root.appendingPathComponent("Datasets").appendingPathComponent(revision)
    }
    public func jobDirectory(_ id: UUID) -> URL { root.appendingPathComponent("Jobs").appendingPathComponent(id.uuidString) }
}
