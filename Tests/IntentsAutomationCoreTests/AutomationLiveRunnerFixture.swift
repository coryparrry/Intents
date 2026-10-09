#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

/// A real, non-child process standing in for an Apple host runner, so release exercises kernel identity, path, and SIGTERM checks.
enum AutomationLiveRunnerFixture {
    struct Runner: Sendable {
        let identity: AutomationProcessIdentity, executable: URL
    }
    /// Replaces a synthetic host executable with a runnable thin Mach-O; product digests are computed afterwards.
    static func installExecutable(at url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try nativeSlice(of: Data(contentsOf: URL(fileURLWithPath: "/bin/sleep"))).write(to: url)
        guard chmod(url.path, 0o755) == 0 else { throw POSIXError(.EPERM) }
        // A thinned platform binary keeps Apple's signature, which the kernel rejects for a copied path.
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", url.path]
        sign.standardOutput = FileHandle.nullDevice; sign.standardError = FileHandle.nullDevice
        try sign.run(); sign.waitUntilExit()
        guard sign.terminationStatus == 0 else { throw POSIXError(.EPERM) }
    }
    /// Host identity accepts only one slice per CPU type, but system binaries ship both arm64 and arm64e.
    private static func nativeSlice(of data: Data) throws -> Data {
        func word(_ offset: Int) -> UInt32 { data[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) } }
        guard data.count >= 8, word(0) == 0xcafebabe else { return data }
        let slices = (0..<Int(word(4))).map { index -> (cpu: UInt32, subtype: UInt32, range: Range<Int>) in
            let base = 8 + index * 20, offset = Int(word(base + 8))
            return (word(base), word(base + 4) & 0x00ff_ffff, offset..<offset + Int(word(base + 12)))
        }
        #if arch(arm64)
        let preferred = slices.filter { $0.cpu == 0x0100000c }.sorted { $0.subtype > $1.subtype }
        #else
        let preferred = slices.filter { $0.cpu == 0x01000007 }
        #endif
        guard let slice = preferred.first, slice.range.upperBound <= data.count else { throw AutomationContractError.invalidIdentity }
        return data.subdata(in: slice.range)
    }
    /// Launches `executable` orphaned to launchd, as a real runner is, so exit is reaped outside the test process.
    static func launch(_ executable: URL, ignoringTerminate: Bool = false, in test: XCTestCase) throws -> Runner {
        let shell = Process(), output = Pipe()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", (ignoringTerminate ? "trap '' TERM; " : "") + "\"$0\" 600 </dev/null >/dev/null 2>&1 & echo $!", executable.path]
        shell.standardOutput = output
        try shell.run(); shell.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(text))
        let deadline = Date().addingTimeInterval(10)
        while executablePath(pid) != executable.path {
            guard Date() < deadline else { kill(pid, SIGKILL); throw AutomationRPCError.timedOut }
            usleep(10_000)
        }
        let identity = try XCTUnwrap(AutomationProcessIdentity.inspect(pid: pid))
        // Never signal a PID that may have been reused by an unrelated process.
        test.addTeardownBlock { if identity.presence() == .matching { kill(pid, SIGKILL) } }
        XCTAssertEqual(identity.presence(), .matching)
        return .init(identity: identity, executable: executable)
    }
    static func executablePath(_ pid: Int32) -> String? {
        var bytes = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        return String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    static func waitUntilGone(_ runner: Runner) async throws -> AutomationProcessIdentity.Presence {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while runner.identity.presence() == .matching || runner.identity.presence() == .unknown, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return runner.identity.presence()
    }
    static func forceStop(_ runner: Runner) async throws {
        kill(runner.identity.pid, SIGKILL)
        _ = try await waitUntilGone(runner)
    }
}
#endif
