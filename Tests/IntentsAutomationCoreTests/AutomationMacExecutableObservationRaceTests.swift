#if os(macOS)
import Darwin
import Foundation
import Synchronization
import XCTest
@testable import IntentsAutomationCore

/// Schedules actual kernel transitions through Reader; it never fabricates a
/// PID, executable path, identity, hash, or kernel error. These regressions do
/// not identify the cause of any historical cleanup failure.
@MainActor
final class AutomationMacExecutableObservationRaceTests: XCTestCase {
    private typealias Inventory = AutomationMacProcessInventory
    private typealias Code = AutomationMacExecutableCodeIdentity
    private let loginSession = "native-kernel-race-fixture"
    private var target: TargetIdentity {
        .init(id: "host-macos-local", kind: .nativeMac, loginSession: loginSession)
    }

    func testRealExecBetweenSelectedPathAndRevalidationRequiresFreshCompleteObservation() async throws {
        let fixture = try NativeFixture.make()
        defer { fixture.remove() }
        let child = OwnedProcess(executable: fixture.helper.executable)
        defer { XCTAssertTrue(child.stopAndReap(), "Test-owned child did not stop within its deadline") }
        let state = NativeInspector(helper: fixture.helper, child: child, mode: .execTransition)
        let verifier = try verifier(fixture.helper, state)
        try await verifier.prepare(target: target, controllerBundleIDs: ["example.NativeOwnedHost.xctrunner"])
        try child.startAndWaitForReady()
        await state.arm()

        let released = await verifier.verifyReleased(target: target, controllerBundleIDs: ["example.NativeOwnedHost.xctrunner"])
        let observed = state.transition.withLock { $0 }
        XCTAssertEqual(observed.firstPath, fixture.helper.executable.path)
        XCTAssertEqual(observed.nextPath, "/bin/sleep")
        XCTAssertEqual(observed.firstIdentity, observed.nextIdentity, "exec must retain this child's PID and birth identity")
        XCTAssertNotNil(observed.firstIdentity)
        XCTAssertEqual(observed.transitionsPerformed, 1)
        XCTAssertTrue(released, "A rejected exec transition needs a new complete helper observation")
        let observations = await verifier.retainedObservations().filter { $0.stage == "release" }
        report(observations, label: "selected-path exec", preferredPID: child.pid)
        XCTAssertFalse(try XCTUnwrap(observations.first).accepted)
        XCTAssertTrue(try XCTUnwrap(observations.last).accepted)
        let forced = observations.filter { $0.failure?.stage == .executableSetChanged && $0.failure?.pid == child.pid }
        XCTAssertEqual(forced.count, 1)
        let raced = try XCTUnwrap(forced.first ?? observations.first)
        XCTAssertNil(raced.inventory)
        XCTAssertEqual(raced.failure?.stage, .executableSetChanged)
        XCTAssertEqual(raced.failure?.errorNumber, 0)
        XCTAssertEqual(observations.last?.inventory?.complete, true)
        XCTAssertEqual(observations.last?.inventory?.executableScope, [fixture.helper.executable.path])
        XCTAssertEqual(observations.last?.inventory?.processes, [])
    }

    func testRealUnlinkedDifferentCodeExitBeforeKernelHashRequiresFreshCompleteObservation() async throws {
        let fixture = try NativeFixture.make(includeDifferentCode: true)
        defer { fixture.remove() }
        let executable = try XCTUnwrap(fixture.other)
        let child = OwnedProcess(executable: executable)
        defer { XCTAssertTrue(child.stopAndReap(), "Test-owned child did not stop within its deadline") }
        let state = NativeInspector(helper: fixture.helper, child: child, mode: .codeIdentityExit)
        let verifier = try verifier(fixture.helper, state)
        try await verifier.prepare(target: target, controllerBundleIDs: ["example.NativeOwnedHost.xctrunner"])
        try child.startAndWaitForReady()
        let selectedHashes = try Code.helperHashes([fixture.helper.executable.path])
        XCTAssertFalse(selectedHashes.contains(try Code.activeHash(child.pid)))
        try FileManager.default.removeItem(at: executable)
        assertRealENOENT(child.pid)
        await state.arm()

        let released = await verifier.verifyReleased(target: target, controllerBundleIDs: ["example.NativeOwnedHost.xctrunner"])
        let observed = state.transition.withLock { $0 }
        XCTAssertNotNil(observed.firstIdentity)
        XCTAssertEqual(observed.transitionsPerformed, 1)
        XCTAssertEqual(observed.kernelErrorNumber, ESRCH, "The native csops error must survive classification")
        XCTAssertFalse(child.isRunning)
        XCTAssertTrue(child.reaped)
        XCTAssertEqual(child.status, 7, "The different-code fixture must exit itself after its gate opens")
        XCTAssertTrue(released, "A kernel-confirmed code-identity exit needs a new complete helper observation")
        let observations = await verifier.retainedObservations().filter { $0.stage == "release" }
        report(observations, label: "unlinked different-code exit", kernelErrno: observed.kernelErrorNumber, preferredPID: child.pid)
        XCTAssertFalse(try XCTUnwrap(observations.first).accepted)
        XCTAssertTrue(try XCTUnwrap(observations.last).accepted)
        let forced = observations.filter { $0.failure?.stage.rawValue == "codeIdentity" && $0.failure?.pid == child.pid }
        XCTAssertEqual(forced.count, 1)
        let raced = try XCTUnwrap(forced.first ?? observations.first)
        XCTAssertNil(raced.inventory)
        // Use its serialized name so the regression compiles before the new
        // production failure stage is introduced, and fails on behavior.
        XCTAssertEqual(raced.failure?.stage.rawValue, "codeIdentity")
        XCTAssertEqual(raced.failure?.errorNumber, ESRCH)
        XCTAssertEqual(observations.last?.inventory?.complete, true)
        XCTAssertEqual(observations.last?.inventory?.executableScope, [fixture.helper.executable.path])
        XCTAssertEqual(observations.last?.inventory?.processes, [])
    }

    func testRealLiveUnlinkedSameCodeCopyRemainsAmbiguousAndReleaseFailsClosed() async throws {
        let fixture = try NativeFixture.make()
        defer { fixture.remove() }
        let copy = fixture.root.appendingPathComponent("same-code-copy")
        try FileManager.default.copyItem(at: fixture.helper.executable, to: copy)
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: fixture.helper.executable))
        let child = OwnedProcess(executable: copy)
        defer { XCTAssertTrue(child.stopAndReap(), "Test-owned child did not stop within its deadline") }
        let state = NativeInspector(helper: fixture.helper, child: child, mode: .sameCodeUnlink)
        let verifier = try verifier(fixture.helper, state)
        try await verifier.prepare(target: target, controllerBundleIDs: ["example.NativeOwnedHost.xctrunner"])
        try child.startAndWaitForReady()
        let hash = try Code.activeHash(child.pid)
        XCTAssertTrue(try Code.helperHashes([fixture.helper.executable.path]).contains(hash))
        try FileManager.default.removeItem(at: copy)
        assertRealENOENT(child.pid)
        XCTAssertEqual(try Code.activeHash(child.pid), hash)
        XCTAssertFalse(try Code.excludes(pid: child.pid, userID: getuid(), paths: [fixture.helper.executable.path]))

        let released = await verifier.verifyReleased(target: target, controllerBundleIDs: ["example.NativeOwnedHost.xctrunner"])
        XCTAssertFalse(released, "Missing path plus matching code is never helper absence")
        XCTAssertTrue(child.isRunning)
        let observations = await verifier.retainedObservations().filter { $0.stage == "release" }
        report(observations, label: "unlinked same-code ambiguity", preferredPID: child.pid)
        XCTAssertTrue(observations.allSatisfy { !$0.accepted })
        XCTAssertEqual(observations.filter { $0.failure?.pid == child.pid }.count, 1)
        let rejected = try XCTUnwrap(observations.last)
        XCTAssertNil(rejected.inventory)
        XCTAssertEqual(rejected.failure?.stage, .executablePath)
        XCTAssertEqual(rejected.failure?.errorNumber, ENOENT)
        XCTAssertEqual(rejected.failure?.pid, child.pid)
    }

    private struct NativeExecutable: Sendable {
        let executable: URL
        let sha256: String
    }

    private func verifier(_ helper: NativeExecutable, _ state: NativeInspector) throws -> AutomationMacAssociatedHostReleaseVerifier {
        let bundle = helper.executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var app = AppIdentity(logicalID: "subject", bundleID: "example.Subject", platform: "macos", productDigest: String(repeating: "a", count: 64))
        app.productDigestVersion = 2
        let host = AutomationPreparedAppleHost(app: app, target: target, xctestrunPath: "unused",
            xctestrunDigest: String(repeating: "b", count: 64), subjectProductPath: "unused", hostBundlePath: bundle.path,
            hostProductDigest: try AutomationProductDigest.compute(bundle: bundle, version: 2),
            hostBundleID: "example.NativeOwnedHost.xctrunner", testTarget: "NativeOwnedHost", hostProductDigestVersion: 2)
        return try .init(host: host, userID: getuid(), inspector: { try await state.inspect() },
            drain: { true }, validateTarget: { _ in })
    }

    private func assertRealENOENT(_ pid: Int32) {
        XCTAssertThrowsError(try Self.kernelPath(pid)) { error in
            let failure = error as? Inventory.KernelObservationFailure
            XCTAssertEqual(failure?.stage, .executablePath)
            XCTAssertEqual(failure?.errorNumber, ENOENT)
            XCTAssertEqual(failure?.pid, pid)
        }
    }

    private func report(_ observations: [AutomationMacAssociatedHostReleaseVerifier.Observation], label: String, kernelErrno: Int32? = nil, preferredPID: Int32? = nil) {
        let failure = observations.first { !$0.accepted && $0.failure?.pid == preferredPID } ?? observations.first { !$0.accepted }
        print("Native associated host cleanup \(label): accepted=\(observations.map(\.accepted)), stage=\(failure?.failure?.stage.rawValue ?? "none"), retainedErrno=\(failure?.failure?.errorNumber.description ?? "none"), actualHashErrno=\(kernelErrno?.description ?? "not sampled")")
    }

    private struct Transition: Sendable {
        var releaseTransitionArmed = false
        var transitionsPerformed = 0
        var pathReads = 0
        var firstPath: String?
        var nextPath: String?
        var firstIdentity: AutomationProcessIdentity?
        var nextIdentity: AutomationProcessIdentity?
        var kernelErrorNumber: Int32?
    }

    private final class TransitionProbe: Sendable {
        private let value = Mutex(Transition())
        func withLock<Result: Sendable>(_ body: @Sendable (inout Transition) throws -> Result) rethrows -> Result {
            try value.withLock { current in try body(&current) }
        }
    }

    private actor NativeInspector {
        enum Mode: Sendable, Equatable { case execTransition, codeIdentityExit, sameCodeUnlink }
        let helper: NativeExecutable
        let child: OwnedProcess
        let mode: Mode
        nonisolated let transition = TransitionProbe()
        init(helper: NativeExecutable, child: OwnedProcess, mode: Mode) {
            self.helper = helper; self.child = child; self.mode = mode
        }
        func arm() { transition.withLock { $0.releaseTransitionArmed = true } }
        func inspect() throws -> Inventory {
            let paths: Set<String> = [helper.executable.path]
            // Prepare and every replacement observation use the production
            // current-UID census. The test explicitly arms only release, and
            // consumes that arm only at the owned child's relevant kernel read.
            guard mode != .sameCodeUnlink, transition.withLock({ $0.releaseTransitionArmed }) else {
                return try Inventory.currentUser(watchedExecutablePaths: paths)
            }
            let child = child, mode = mode, transition = transition, uid = getuid()
            transition.withLock { $0.pathReads = 0 }
            let hashes = try Code.helperHashes(paths)
            let reader = Inventory.Reader(processIDs: Self.kernelPIDs,
                identity: { pid, userID in
                    let identity = try Inventory.info(pid: pid, userID: userID)
                    if pid == child.pid { transition.withLock { $0.firstIdentity = identity } }
                    return identity
                }, executablePath: { pid in
                    let path = try AutomationMacExecutableObservationRaceTests.kernelPath(pid)
                    guard pid == child.pid, mode == .execTransition else { return path }
                    let shouldTransition = transition.withLock { value in
                        guard value.releaseTransitionArmed else { return false }
                        value.pathReads += 1
                        if value.pathReads == 1 { value.firstPath = path }
                        guard value.pathReads == 2 else { return false }
                        value.releaseTransitionArmed = false
                        value.transitionsPerformed += 1
                        return true
                    }
                    guard shouldTransition else { return path }
                    try child.sendCommand(69) // E: exec the existing /bin/sleep.
                    let changed = try AutomationMacExecutableObservationRaceTests.waitForChangedPath(pid, from: path)
                    let identity = try Inventory.info(pid: pid, userID: uid)
                    transition.withLock { $0.nextPath = changed; $0.nextIdentity = identity }
                    return changed
                }, excludesUnreadableExecutable: { pid, userID in
                    guard pid == child.pid, mode == .codeIdentityExit else {
                        return try Code.excludes(pid: pid, userID: userID, paths: paths)
                    }
                    return try Code.excludes(pid: pid, userID: userID, hashes: hashes,
                        identity: { pid, userID in
                            let identity = try Inventory.info(pid: pid, userID: userID)
                            let shouldTransition = transition.withLock { value in
                                guard value.releaseTransitionArmed else { return false }
                                value.releaseTransitionArmed = false
                                value.transitionsPerformed += 1
                                value.firstIdentity = identity
                                return true
                            }
                            guard shouldTransition else { return identity }
                            try child.sendCommand(88) // X: exit, then reap this exact owned child.
                            guard child.waitForExit(seconds: 5) else { throw FixtureFailure.timeout("owned child exit") }
                            return identity
                        }, hash: { pid in
                            do { return try Code.activeHash(pid) }
                            catch {
                                // Save the real failed csops errno before other
                                // diagnostics; do not turn it into an injected error.
                                let actual = (error as? Inventory.KernelObservationFailure)?.errorNumber ?? errno
                                transition.withLock { $0.kernelErrorNumber = actual }
                                throw error
                            }
                        })
                })
            return try Inventory.collectExecutables(userID: uid, paths: paths, reader: reader,
                inactive: { try Inventory.inactiveProcess(pid: $0, userID: uid) })
        }

        /// Matches the production bounded PROC_UID_ONLY enumeration; every PID
        /// is supplied by libproc, including unrelated current-UID processes.
        private static func kernelPIDs(_ uid: UInt32) throws -> Set<Int32> {
            let size = Int32(MemoryLayout<Int32>.size)
            let requested = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
            guard requested > 0 else { throw Inventory.KernelObservationFailure(stage: .pidList, pid: nil, errorNumber: errno) }
            guard requested % size == 0, requested <= 8192 * size else { throw AutomationContractError.terminationUnverified }
            let capacity = min(8192, Int(requested / size) + 128)
            var pids = [Int32](repeating: 0, count: capacity)
            let returned = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), uid, $0.baseAddress, Int32($0.count)) }
            guard returned > 0 else { throw Inventory.KernelObservationFailure(stage: .pidList, pid: nil, errorNumber: errno) }
            guard returned % size == 0, returned < capacity * Int(size) else { throw AutomationContractError.terminationUnverified }
            let values = Array(pids.prefix(Int(returned / size))).filter { $0 > 0 }
            let result = Set(values)
            guard result.count == values.count, result.contains(getpid()) else { throw AutomationContractError.terminationUnverified }
            return result
        }
    }

    private nonisolated static func kernelPath(_ pid: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { throw Inventory.KernelObservationFailure(stage: .executablePath, pid: pid, errorNumber: errno) }
        guard length < buffer.count, let end = buffer.firstIndex(of: 0), end > 0,
              let path = String(bytes: buffer[..<end].map { UInt8(bitPattern: $0) }, encoding: .utf8),
              Inventory.validExecutablePath(path) else { throw AutomationContractError.terminationUnverified }
        return path
    }

    private nonisolated static func waitForChangedPath(_ pid: Int32, from selected: String) throws -> String {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let path = try kernelPath(pid)
            if path != selected { return path }
            Thread.sleep(forTimeInterval: 0.005)
        }
        throw FixtureFailure.timeout("kernel exec path transition")
    }

    private enum FixtureFailure: Error { case timeout(String), io(Int32), badReadyByte, compileFailed(Int32), signingFailed(Int32) }

    private struct NativeFixture {
        let root: URL
        let helper: NativeExecutable
        let other: URL?
        static func make(includeDifferentCode: Bool = false) throws -> Self {
            let requested = FileManager.default.temporaryDirectory.appendingPathComponent("native-helper-race-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: false)
            let root: URL
            do { root = try AutomationPath.canonical(requested) }
            catch { try? FileManager.default.removeItem(at: requested); throw error }
            do {
                let bundle = root.appendingPathComponent("NativeOwnedHost-Runner.app")
                let directory = bundle.appendingPathComponent("Contents/MacOS")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "example.NativeOwnedHost.xctrunner",
                    "CFBundleExecutable": "NativeOwnedHost-Runner", "CFBundleSupportedPlatforms": ["MacOSX"]]
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                    .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
                let selected = directory.appendingPathComponent("NativeOwnedHost-Runner")
                try compile(root: root, executable: selected, exitCode: 0)
                // The linker signs a standalone Mach-O. Once placed in an app
                // layout, strict Security validation also requires the bundle's
                // Info.plist/resource seal. Match the prepared-host contract
                // before taking its immutable product digest or spawning it.
                try seal(bundle: bundle)
                let other = includeDifferentCode ? root.appendingPathComponent("different-code") : nil
                if let other { try compile(root: root, executable: other, exitCode: 7) }
                return .init(root: root, helper: .init(executable: selected,
                    sha256: AutomationArtifactRegistry.digest(try Data(contentsOf: selected))), other: other)
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        private static func seal(bundle: URL) throws {
            for arguments in [["--force", "--sign", "-", bundle.path], ["--verify", "--strict", bundle.path]] {
                let signer = OwnedProcess(executable: URL(fileURLWithPath: "/usr/bin/codesign"), arguments: arguments)
                defer { XCTAssertTrue(signer.stopAndReap(), "Test-owned signer did not stop within its deadline") }
                try signer.start()
                guard signer.waitForExit(seconds: 15) else { throw FixtureFailure.timeout("fixture signing") }
                guard signer.status == 0 else { throw FixtureFailure.signingFailed(signer.status) }
            }
        }

        private static func compile(root: URL, executable: URL, exitCode: Int) throws {
            let source = root.appendingPathComponent(executable.lastPathComponent + ".c")
            let body = """
            #include <unistd.h>
            #include <signal.h>
            #include <errno.h>
            int main(void) {
                char command;
                alarm(30);
                if (write(1, "R", 1) != 1) return 11;
                ssize_t count;
                do { count = read(0, &command, 1); } while (count < 0 && errno == EINTR);
                if (count != 1) return 12;
                if (command == 'E') {
                    execl("/bin/sleep", "sleep", "20", (char *)0);
                    return 13;
                }
                return \(exitCode);
            }
            """
            try Data(body.utf8).write(to: source)
            let compiler = OwnedProcess(executable: URL(fileURLWithPath: "/usr/bin/cc"),
                arguments: [source.path, "-o", executable.path, "-Wl,-adhoc_codesign"])
            defer { XCTAssertTrue(compiler.stopAndReap(), "Test-owned compiler did not stop within its deadline") }
            try compiler.start()
            guard compiler.waitForExit(seconds: 30) else { throw FixtureFailure.timeout("fixture compiler") }
            guard compiler.status == 0 else { throw FixtureFailure.compileFailed(compiler.status) }
        }
    }

    /// A single inspector uses these handles serially, and tests await it before
    /// cleanup. Only this handle calls waitpid: an unreaped child keeps its PID
    /// reserved through termination, eliminating an asynchronous-reaper race.
    private final class OwnedProcess: @unchecked Sendable {
        private let executable: URL
        private let arguments: [String]
        private let input = Pipe(), output = Pipe()
        private var processID: Int32 = 0
        private var waitStatus: Int32 = 0
        private var started = false
        private var lostOwnership = false
        private(set) var reaped = false
        var pid: Int32 { processID }
        var isRunning: Bool {
            started && !reaped && !lostOwnership &&
                (try? Inventory.inactiveProcess(pid: pid, userID: getuid())) == false
        }
        var status: Int32 {
            let signal = waitStatus & 0x7f
            return signal == 0 ? (waitStatus >> 8) & 0xff : -signal
        }
        init(executable: URL, arguments: [String] = []) {
            self.executable = executable; self.arguments = arguments
        }
        func start() throws {
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                throw FixtureFailure.io(errno)
            }
            var actions: posix_spawn_file_actions_t?
            try check(posix_spawn_file_actions_init(&actions))
            defer { posix_spawn_file_actions_destroy(&actions) }
            try check(posix_spawn_file_actions_adddup2(&actions, input.fileHandleForReading.fileDescriptor, STDIN_FILENO))
            try check(posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO))
            for descriptor in [input.fileHandleForReading.fileDescriptor, input.fileHandleForWriting.fileDescriptor,
                               output.fileHandleForReading.fileDescriptor, output.fileHandleForWriting.fileDescriptor]
            where descriptor != STDIN_FILENO && descriptor != STDOUT_FILENO {
                try check(posix_spawn_file_actions_addclose(&actions, descriptor))
            }
            var argv = ([executable.path] + arguments).map { strdup($0) }
            var environment = ProcessInfo.processInfo.environment.map { strdup($0.key + "=" + $0.value) }
            defer {
                for value in argv { if let value { free(value) } }
                for value in environment { if let value { free(value) } }
            }
            guard argv.allSatisfy({ $0 != nil }), environment.allSatisfy({ $0 != nil }) else {
                throw FixtureFailure.io(ENOMEM)
            }
            argv.append(nil); environment.append(nil)
            try check(posix_spawn(&processID, executable.path, &actions, nil, &argv, &environment))
            started = true
            try input.fileHandleForReading.close()
            try output.fileHandleForWriting.close()
        }
        func startAndWaitForReady() throws {
            try start()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            while ContinuousClock.now < deadline {
                let ready = poll(&descriptor, 1, 100)
                if ready < 0 { if errno == EINTR { continue }; throw FixtureFailure.io(errno) }
                guard ready > 0 else { continue }
                var byte: UInt8 = 0
                let count = Darwin.read(descriptor.fd, &byte, 1)
                if count < 0, errno == EINTR { continue }
                guard count == 1, byte == 82 else { throw FixtureFailure.badReadyByte }
                return
            }
            throw FixtureFailure.timeout("fixture readiness")
        }
        func sendCommand(_ byte: UInt8) throws {
            var byte = byte
            guard Darwin.write(input.fileHandleForWriting.fileDescriptor, &byte, 1) == 1 else { throw FixtureFailure.io(errno) }
        }
        func waitForExit(seconds: Double) -> Bool {
            guard started else { return true }
            if reaped { return true }
            guard !lostOwnership else { return false }
            let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
            repeat {
                var value: Int32 = 0
                let result = waitpid(pid, &value, WNOHANG)
                if result == pid { waitStatus = value; reaped = true; return true }
                if result == -1 {
                    if errno == EINTR { continue }
                    // Another reaper must never cause a signal to a reused PID.
                    if errno == ECHILD { lostOwnership = true }
                    return false
                }
                if ContinuousClock.now >= deadline { return false }
                Thread.sleep(forTimeInterval: 0.005)
            } while ContinuousClock.now < deadline
            return false
        }
        @discardableResult func stopAndReap() -> Bool {
            guard started, !reaped else { return true }
            if waitForExit(seconds: 0) { return true }
            guard !lostOwnership else { return false }
            _ = kill(pid, SIGTERM)
            if waitForExit(seconds: 2) { return true }
            guard !lostOwnership else { return false }
            _ = kill(pid, SIGKILL)
            return waitForExit(seconds: 2)
        }
        private func check(_ code: Int32) throws {
            guard code == 0 else { throw FixtureFailure.io(code) }
        }
    }
}
#endif
