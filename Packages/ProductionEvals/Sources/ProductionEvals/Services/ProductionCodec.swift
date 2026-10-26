import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ProductionCodec {
    /// Encodes sorted-key JSON with unescaped slashes and rounded integer Unix milliseconds for stable content hashing.
    /// - Throws: Encoding errors or an invalid-date error outside the representable millisecond range.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            let milliseconds = (date.timeIntervalSince1970*1000).rounded()
            guard milliseconds.isFinite, let integer = Int64(exactly: milliseconds) else {
                throw ProductionFailure.invalid("Date exceeds the representable Unix millisecond range.")
            }
            try value.encode(integer)
        }
        return try encoder.encode(value)
    }
    /// Reproduces the earlier millisecond date encoding only for verification of previously frozen revisions.
    static func legacyEncode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970; return try encoder.encode(value)
    }
    /// Decodes stored JSON using Unix millisecond timestamps and propagates decoding failures.
    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
    /// Returns the lowercase hexadecimal SHA-256 digest of the supplied bytes.
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    /// Streams a file in 64 KiB blocks to compute its lowercase SHA-256 digest without loading it all at once.
    public static func fileDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 65_536), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    /// Uses the first 16 SHA-256 bytes of the UTF-8 value as a deterministic UUID.
    public static func stableID(_ value: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                           bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    /// Encodes and atomically replaces a JSON file, then synchronizes its handle.
    /// - Parameter maximumBytes: Optional encoded byte ceiling checked before replacement.
    /// - Throws: Encoding, size-limit, or file-system errors.
    public static func write<T: Encodable>(_ value: T, to url: URL, maximumBytes: Int? = nil) throws {
        let data = try encode(value)
        if let maximumBytes, data.count > maximumBytes {
            throw ProductionFailure.invalid("Stored record exceeds its size limit.")
        }
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }; try handle.synchronize()
    }
    /// Reads the current filesystem size without relying on cached URL resource values.
    /// - Throws: File-system errors or an integrity error if no numeric size is available.
    public static func fileSize(_ url: URL) throws -> Int {
        // URL resource values are cached; live worker output must be measured from the filesystem.
        guard let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else { throw ProductionFailure.integrity("Cannot read file size.") }
        return size.intValue
    }
    /// Rejects files above `maximumBytes` before loading and decoding their JSON contents.
    public static func read<T: Decodable>(_ type: T.Type, from url: URL, maximumBytes: Int = 70_000_000) throws -> T {
        let size = try fileSize(url)
        guard size <= maximumBytes else { throw ProductionFailure.invalid("Stored record exceeds its size limit.") }
        return try decode(type, Data(contentsOf: url))
    }
    /// Rejects content revisions that are not 64 lowercase hexadecimal characters.
    static func validateDigest(_ value: String) throws {
        guard value.count == 64, value.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw ProductionFailure.invalid("Invalid content revision.")
        }
    }
}

/// File-system transactions coordinate app and CLI processes. Storage must support flock and atomic rename.
public final class ProductionStorage: @unchecked Sendable {
    public let root: URL
    private let claimProgressLock = NSLock()
    private var completedClaimPrefixes: [String: Int] = [:]

    // Completed chunks with no live lease cannot be edited through this API.
    // Cache only that immutable prefix, never pending/leased/worker-specific
    // work. New storage instances rebuild the prefix from validated chunks;
    // reports independently validate the saved evidence on every read.
    /// Reads the cached start of the contiguous completed chunk prefix for this job revision under a local lock.
    func claimStartIndex(_ job: ProductionJob) -> Int {
        claimProgressLock.withLock { completedClaimPrefixes[job.revision] ?? 0 }
    }

    /// Advances the cached completed prefix only when this chunk is the next contiguous completed entry.
    func advanceClaimPrefix(_ job: ProductionJob, completedIndex: Int) {
        claimProgressLock.withLock {
            if (completedClaimPrefixes[job.revision] ?? 0) == completedIndex {
                completedClaimPrefixes[job.revision] = completedIndex + 1
            }
        }
    }

    /// Creates the local store root and its dataset, job, worker, review, and schedule directories.
    /// - Throws: File-system errors while establishing the directory structure.
    public init(root: URL) throws {
        self.root = root.standardizedFileURL
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        for folder in ["Datasets", "Jobs", "Workers", "Reviews", "Schedules"] {
            try FileManager.default.createDirectory(at: self.root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
    }
    /// Runs the synchronous operation under an exclusive cross-process file lock, releasing it on success or error.
    /// Requires storage that supports `flock`; opening or acquiring the lock can throw an unavailable error.
    func transaction<T>(_ operation: () throws -> T) throws -> T {
        let path = root.appendingPathComponent(".store.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw ProductionFailure.unavailable("Cannot open storage transaction lock.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw ProductionFailure.unavailable("Cannot lock production storage.") }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }
    /// Validates a digest-shaped revision before resolving its dataset directory under the store root.
    public func datasetDirectory(_ revision: String) throws -> URL {
        try ProductionCodec.validateDigest(revision)
        return root.appendingPathComponent("Datasets").appendingPathComponent(revision)
    }
    /// Resolves the UUID-named directory for a job under this store root.
    public func jobDirectory(_ id: UUID) -> URL { root.appendingPathComponent("Jobs").appendingPathComponent(id.uuidString) }
}
