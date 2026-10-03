import Foundation
import CryptoKit
import Darwin

/// Opt-in local JSONL capture. The integrating app owns consent and sanitization; no network traffic is sent.
public actor DeveloperProductionCapture {
    public struct Record: Codable, Sendable {
        public var id: String
        public var sourceID: String
        public var prompt: String
        public var capturedOutput: String
        public var feedback: String?
        public var expected: String? = nil
        public var partition = "regression"
        public var metadata: [String: String]
    }
    private let file: URL
    private let sourceKey: SymmetricKey
    private let metadataKeys: Set<String>
    private let sanitizer: @Sendable (String) throws -> String
    private var enabled = false
    private let maximumFileBytes: UInt64
    public init(file: URL, sourceKey: Data, metadataKeys: Set<String>, maximumFileBytes: UInt64 = 50_000_000, sanitizer: @escaping @Sendable (String) throws -> String) throws {
        guard sourceKey.count >= 32, metadataKeys.count <= 12, maximumFileBytes >= 262_144 else { throw CaptureError.invalidConfiguration }
        self.maximumFileBytes = maximumFileBytes
        self.file = file; self.sourceKey = SymmetricKey(data: sourceKey); self.metadataKeys = metadataKeys; self.sanitizer = sanitizer
    }
    public func setEnabled(_ enabled: Bool) { self.enabled = enabled }
    @discardableResult
    public func record(eventID: String, sourceID: String, prompt: String, output: String, feedback: String? = nil,
                       metadata: [String: String] = [:]) throws -> Bool {
        guard enabled else { return false }
        let sanitizedPrompt = try sanitizer(prompt), sanitizedOutput = try sanitizer(output)
        let sanitizedFeedback = try feedback.map(sanitizer)
        var permitted: [String: String] = [:]
        for (key,value) in metadata where metadataKeys.contains(key) { permitted[key] = try sanitizer(value) }
        guard !eventID.isEmpty, !sourceID.isEmpty, !sanitizedPrompt.isEmpty, sanitizedPrompt.utf8.count <= 64_000,
              sanitizedOutput.utf8.count <= 64_000, (sanitizedFeedback?.utf8.count ?? 0) <= 4_000,
              permitted.allSatisfy({ $0.key.count <= 80 && $0.value.count <= 200 }) else { throw CaptureError.oversizedRecord }
        func pseudonym(_ value: String) -> String {
            HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: sourceKey).map { String(format: "%02x", $0) }.joined()
        }
        let value = Record(id: pseudonym(eventID), sourceID: pseudonym(sourceID), prompt: sanitizedPrompt,
                           capturedOutput: sanitizedOutput, feedback: sanitizedFeedback, metadata: permitted)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; var data = try encoder.encode(value); data.append(10)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(file.path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { try? handle.close() }
        guard flock(handle.fileDescriptor, LOCK_EX) == 0 else { throw CaptureError.invalidConfiguration }
        defer { _ = flock(handle.fileDescriptor, LOCK_UN) }
        let size = try handle.seekToEnd()
        guard size + UInt64(data.count) <= maximumFileBytes else { throw CaptureError.retentionLimit }
        try handle.write(contentsOf: data); try handle.synchronize(); return true
    }
    public enum CaptureError: Error { case invalidConfiguration, oversizedRecord, retentionLimit }
}
