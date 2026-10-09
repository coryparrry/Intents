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
        let shell = Process(), output = Pipe(), acknowledgement = Pipe()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", (ignoringTerminate ? "trap '' TERM; " : "") + "\"$0\" 600 </dev/null >/dev/null 2>&1 & child=$!; printf '%s\\n' \"$child\"; IFS= read -r acknowledgement", executable.path]
        shell.standardOutput = output; shell.standardInput = acknowledgement
        try shell.run()
        defer {
            try? acknowledgement.fileHandleForWriting.close()
            shell.waitUntilExit()
        }
        let text = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(text))
        // Bind the PID while the launcher is still its parent, before orphaning it to launchd.
        // A reused PID or an unstable identity never authorizes cleanup.
        let identity = try captureOwnedIdentity(pid: pid, launcherPID: shell.processIdentifier)
        test.addTeardownBlock { _ = signalIfMatching(identity) }
        try? acknowledgement.fileHandleForWriting.close()
        shell.waitUntilExit()
        do { try waitForExecutable(identity, executable: executable) }
        catch { signalIfMatching(identity); throw error }
        XCTAssertEqual(identity.presence(), .matching)
        return .init(identity: identity, executable: executable)
    }
    static func captureOwnedIdentity(pid: Int32, launcherPID: Int32,
                                     inspect: (Int32) -> AutomationProcessIdentity? = { AutomationProcessIdentity.inspect(pid: $0) },
                                     parent: (Int32) -> Int32? = { parentPID($0) }) throws -> AutomationProcessIdentity {
        guard let identity = inspect(pid), parent(pid) == launcherPID, inspect(pid) == identity else {
            throw AutomationContractError.invalidIdentity
        }
        return identity
    }
    private static func parentPID(_ pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_ppid <= UInt32(Int32.max) else { return nil }
        return Int32(info.pbi_ppid)
    }
    @discardableResult
    static func signalIfMatching(_ identity: AutomationProcessIdentity,
                                 presence: (AutomationProcessIdentity) -> AutomationProcessIdentity.Presence = { $0.presence() },
                                 signal: (Int32, Int32) -> Int32 = { kill($0, $1) }) -> Bool {
        guard presence(identity) == .matching else { return false }
        return signal(identity.pid, SIGKILL) == 0
    }
    static func waitForExecutable(_ identity: AutomationProcessIdentity, executable: URL,
                                  timeout: Duration = .seconds(10),
                                  presence: (AutomationProcessIdentity) -> AutomationProcessIdentity.Presence = { $0.presence() },
                                  path: (Int32) -> String? = { executablePath($0) }) throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            guard presence(identity) == .matching else { throw AutomationContractError.invalidIdentity }
            if path(identity.pid) == executable.path {
                guard presence(identity) == .matching else { throw AutomationContractError.invalidIdentity }
                return
            }
            guard ContinuousClock.now < deadline else { throw AutomationRPCError.timedOut }
            usleep(10_000)
        }
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
        if !signalIfMatching(runner.identity) {
            guard [.absent, .replaced].contains(runner.identity.presence()) else { throw AutomationContractError.terminationUnverified }
            return
        }
        let presence = try await waitUntilGone(runner)
        guard [.absent, .replaced].contains(presence) else { throw AutomationContractError.terminationUnverified }
    }
}
#endif
