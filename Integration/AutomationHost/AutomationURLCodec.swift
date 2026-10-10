import Foundation

/// A URL reference, with no file access, bookmark resolution or network request.
/// This adapter currently accepts exact absolute HTTP(S) URLs only.
public struct AutomationURLReference: Equatable, Sendable {
    public let absoluteString: String
    public init(_ absoluteString: String) throws {
        self.absoluteString = absoluteString
        _ = try url()
    }
    public func url() throws -> URL {
        guard (1...4096).contains(absoluteString.utf8.count),
              absoluteString.utf8.allSatisfy({ (33...126).contains($0) }),
              let components = URLComponents(string: absoluteString),
              let scheme = components.scheme, ["http", "https"].contains(scheme), components.host?.isEmpty == false,
              components.user == nil, components.password == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              let url = components.url, url.baseURL == nil, !url.isFileURL,
              url.absoluteString == absoluteString else { throw Self.invalid() }
        return url
    }
    public static func encode(_ url: URL) throws -> Self {
        guard url.baseURL == nil, !url.isFileURL else { throw invalid() }
        return try .init(url.absoluteString)
    }
    private static func invalid() -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: "URL reference requires an exact absolute HTTP(S) URL without credentials, file access or normalization"))
    }
}
