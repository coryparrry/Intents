#if os(macOS)
import XCTest
import Darwin
import Foundation
import Synchronization
@testable import IntentsAutomationCore

final class AutomationMacExecutableCodeIdentityTests: XCTestCase {
    private typealias Code = AutomationMacExecutableCodeIdentity
    private let helper = Data(repeating: 1, count: 20)
    private let other = Data(repeating: 2, count: 20)
    private func identity(_ pid: Int32, _ userID: UInt32) -> AutomationProcessIdentity {
        .init(pid: pid, startIdentity: "100:0")
    }
    func testDifferentStableKernelCodeIdentityExcludesButMatchingDoesNot() throws {
        XCTAssertTrue(try Code.excludes(pid: 42, userID: 501, hashes: [helper], identity: identity, hash: { _ in self.other }))
        XCTAssertFalse(try Code.excludes(pid: 42, userID: 501, hashes: [helper, other], identity: identity, hash: { _ in self.other }))
    }
    func testMissingMalformedAndChangingObservationsFailClosed() throws {
        for hashes: Set<Data> in [[], [Data()], [Data(repeating: 0, count: 20)]] {
            XCTAssertThrowsError(try Code.excludes(pid: 42, userID: 501, hashes: hashes, identity: identity, hash: { _ in self.other }))
        }
        for bytes in [Data(), Data(repeating: 0, count: 20)] {
            XCTAssertThrowsError(try Code.excludes(pid: 42, userID: 501, hashes: [helper], identity: identity, hash: { _ in bytes }))
        }
        let calls = Mutex(0)
        XCTAssertThrowsError(try Code.excludes(pid: 42, userID: 501, hashes: [helper], identity: identity, hash: { _ in
            calls.withLock { $0 += 1; return $0 == 1 ? self.other : self.helper }
        }))
        let starts = Mutex(0)
        XCTAssertThrowsError(try Code.excludes(pid: 42, userID: 501, hashes: [helper], identity: { pid, _ in
            .init(pid: pid, startIdentity: starts.withLock { $0 += 1; return String($0) + ":0" })
        }, hash: { _ in self.other }))
        XCTAssertThrowsError(try Code.excludes(pid: 42, userID: 501, hashes: [helper], identity: identity, hash: { _ in throw POSIXError(.EACCES) }))
    }
    func testInventoryRequiresPositiveExclusionForUnreadableLiveExecutable() throws {
        var reader = AutomationMacProcessInventory.Reader(processIDs: { _ in [42] }, identity: { pid, _ in .init(pid: pid, startIdentity: "100:0") },
            executablePath: { pid in throw AutomationMacProcessInventory.KernelObservationFailure(stage: .executablePath, pid: pid, errorNumber: ENOENT) })
        reader.excludesUnreadableExecutable = { _, _ in true }
        XCTAssertTrue(try AutomationMacProcessInventory.collectExecutables(userID: 501, paths: ["/bin/helper"], reader: reader, inactive: { _ in false }).processes.isEmpty)
        var denied = reader
        denied.executablePath = { pid in throw AutomationMacProcessInventory.KernelObservationFailure(stage: .executablePath, pid: pid, errorNumber: EACCES) }
        denied.excludesUnreadableExecutable = { _, _ in XCTFail("Permission errors cannot use the deleted-file fallback"); return true }
        XCTAssertThrowsError(try AutomationMacProcessInventory.collectExecutables(userID: 501, paths: ["/bin/helper"], reader: denied, inactive: { _ in false }))
        reader.excludesUnreadableExecutable = { _, _ in false }
        XCTAssertThrowsError(try AutomationMacProcessInventory.collectExecutables(userID: 501, paths: ["/bin/helper"], reader: reader, inactive: { _ in false }))
        reader.excludesUnreadableExecutable = { _, _ in throw POSIXError(.EACCES) }
        XCTAssertThrowsError(try AutomationMacProcessInventory.collectExecutables(userID: 501, paths: ["/bin/helper"], reader: reader, inactive: { _ in false }))
    }
    func testNodeSizedExecutableReachesStrictSignatureCheckAndOversizedFileIsRefused() throws {
        let root = URL(fileURLWithPath: "/private/tmp/intents-code-identity-size-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("node")
        // A recognized arm64 Mach-O header with no valid signature. Passing
        // the old 16 MiB read boundary must never bypass signature admission.
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]).write(to: executable)
        let handle = try FileHandle(forWritingTo: executable)
        try handle.truncate(atOffset: 17 * 1024 * 1024); try handle.close()
        XCTAssertThrowsError(try Code.helperHashes([executable.path])) {
            XCTAssertEqual($0 as? AutomationContractError, .terminationUnverified)
        }
        let oversized = try FileHandle(forWritingTo: executable)
        try oversized.truncate(atOffset: UInt64(Code.maximumExecutableBytes) + 1); try oversized.close()
        XCTAssertThrowsError(try Code.helperHashes([executable.path])) {
            XCTAssertEqual($0 as? AutomationContractError, .invalidIdentity)
        }
    }
    func testLiveUnlinkedExecutableRetainsKernelCodeIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("sleep")
        let source = root.appendingPathComponent("fixture.c")
        let helper = root.appendingPathComponent("other-helper")
        func compile(_ body: String, to binary: URL) throws {
            try Data(body.utf8).write(to: source)
            let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            compiler.arguments = ["clang", source.path, "-o", binary.path]
            let completed = DispatchSemaphore(value: 0)
            compiler.terminationHandler = { _ in completed.signal() }
            try compiler.run()
            guard completed.wait(timeout: .now() + 30) == .success else {
                XCTAssertTrue(stop(compiler, completion: completed), "Compiler fixture did not terminate")
                throw POSIXError(.ETIMEDOUT)
            }
            XCTAssertEqual(compiler.terminationStatus, 0)
        }
        try compile("#include <unistd.h>\nint main(void) { write(1, \"R\", 1); sleep(30); return 0; }\n", to: executable)
        try compile("int main(void) { return 7; }\n", to: helper)
        let sleepHashes = try Code.helperHashes([executable.path])
        let process = Process(); process.executableURL = executable; process.arguments = ["30"]
        let ready = Pipe(); process.standardOutput = ready
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        defer { XCTAssertTrue(stop(process, completion: completed), "Test-owned child did not stop within its deadline") }
        XCTAssertEqual(try ready.fileHandleForReading.read(upToCount: 1), Data("R".utf8))
        let hash = try Code.activeHash(process.processIdentifier)
        XCTAssertTrue(sleepHashes.contains(hash))
        try FileManager.default.removeItem(at: executable)
        var path = [CChar](repeating: 0, count: 4096)
        XCTAssertEqual(proc_pidpath(process.processIdentifier, &path, UInt32(path.count)), 0)
        XCTAssertEqual(try Code.activeHash(process.processIdentifier), hash)
        XCTAssertTrue(try Code.excludes(pid: process.processIdentifier, userID: getuid(), paths: [helper.path]))
        let inventory = try AutomationMacProcessInventory.currentUser(helperExecutablePaths: [helper.path])
        XCTAssertTrue(inventory.processes.isEmpty)
        try inventory.validate(expectedUserID: getuid(), matchingExecutablePaths: [helper.path])
        XCTAssertFalse(try Code.excludes(pid: process.processIdentifier, userID: getuid(), hashes: sleepHashes,
            identity: { try AutomationMacProcessInventory.info(pid: $0, userID: $1) }, hash: Code.activeHash))
    }
    private func stop(_ process: Process, completion: DispatchSemaphore) -> Bool {
        if !process.isRunning { return true }
        process.terminate()
        if completion.wait(timeout: .now() + 5) == .success { return true }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        return completion.wait(timeout: .now() + 5) == .success
    }

}
#endif
