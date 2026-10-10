import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum AutomationPath {
    /// Use the same realpath contract as Node; Foundation can prefer /tmp over /private/tmp.
    public static func canonical(_ url: URL) throws -> URL {
        guard url.isFileURL, !url.path.contains("\0"), let pointer = realpath(url.path, nil) else { throw AutomationContractError.invalidIdentity }
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer))
    }
}
