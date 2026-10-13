#if os(macOS)
import Foundation
@testable import IntentsAutomationCore

/// Test fixtures use Xcode's Python standard library, without a shipped UI runtime.
enum AutomationSyntheticPython {
    static func executable() throws -> URL {
        let finder = Process(), output = Pipe(), errors = Pipe()
        finder.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        finder.arguments = ["--find", "python3"]
        finder.standardOutput = output; finder.standardError = errors
        try finder.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        finder.waitUntilExit()
        let path = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard finder.terminationStatus == 0, !path.isEmpty else {
            throw AutomationContractError.missingEvidence("Xcode Python is required for the synthetic owned-process fixture")
        }
        let executable = try AutomationPath.canonical(URL(fileURLWithPath: path))
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw AutomationContractError.invalidIdentity }
        return executable
    }
}
#endif
