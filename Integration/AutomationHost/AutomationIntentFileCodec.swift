import Foundation
import CryptoKit

/// Closed data-only file transport. No paths, bookmarks or executable content semantics.
public struct AutomationIntentFileMetadata: Codable, Equatable, Sendable {
    public let filename: String
    public let typeIdentifier: String?
    public let byteCount: Int
    public let sha256: String
    public init(filename: String, typeIdentifier: String?, data: Data) throws {
        guard data.count <= 8192 else { throw Self.invalid() }
        self.filename = filename; self.typeIdentifier = typeIdentifier; byteCount = data.count
        sha256 = Self.digest(data); try validate()
    }
    public func validate() throws {
        guard filename.utf8.count <= 128, filename.range(of: #"^[A-Za-z0-9][A-Za-z0-9 _.-]{0,127}\z"#, options: .regularExpression) != nil,
              filename != ".", filename != "..", byteCount >= 0, byteCount <= 8192,
              typeIdentifier == nil || ["public.data", "public.plain-text", "public.json"].contains(typeIdentifier!),
              sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw Self.invalid() }
    }
    public func verify(_ data: Data) throws {
        try validate()
        guard data.count == byteCount, Self.digest(data) == sha256 else { throw Self.invalid() }
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func invalid() -> DecodingError { .dataCorrupted(.init(codingPath: [], debugDescription: "File transport requires bounded bytes and exact file metadata")) }
}

/// Immutable synthetic calibration data; callers cannot supply file bytes or paths.
public enum AutomationIntentFileCalibration {
    public static let data = Data("Intents file adapter calibration".utf8)
    public static let filename = "intents-calibration.txt"
    public static let typeIdentifier = "public.plain-text"
    public static func metadata() throws -> AutomationIntentFileMetadata { try .init(filename: filename, typeIdentifier: typeIdentifier, data: data) }
}
