#if os(macOS)
import Foundation
@testable import IntentsAutomationCore

enum AutomationServedJavaScriptTestEvidence {
    /// Preserve only bounded diagnostics; no customer sources, bundle bodies,
    /// runtime executables or private Metro authorization tokens are copied.
    static func retain(root: URL, evidenceRoot: URL, error: any Error) throws -> URL {
        let destination = evidenceRoot.appendingPathComponent("served-js-failure-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try AutomationDurableFile(url: destination.appendingPathComponent("test-error.txt"), maximumBytes: 4096)
            .write(Data(String(String(describing: error).prefix(2048)).utf8))
        let sessions = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("served-js-") }.sorted { $0.path < $1.path }
        guard sessions.count <= 8 else { throw AutomationContractError.invalidIdentity }
        for session in sessions {
            guard try AutomationPath.canonical(session).path == session.path else { throw AutomationContractError.invalidIdentity }
            for (name, limit) in [("server.log", 4_194_304), ("failure.json", 16_384), ("openssl.cnf", 4096)] {
                let file = session.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let data = try AutomationReadOnlyFile.read(file, maximumBytes: limit)
                try AutomationDurableFile(url: destination.appendingPathComponent(session.lastPathComponent).appendingPathComponent(name), maximumBytes: limit).write(data)
            }
        }
        return destination
    }
}

#endif
