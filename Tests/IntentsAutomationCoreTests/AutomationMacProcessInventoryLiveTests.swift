#if os(macOS)
import XCTest
import Darwin
@testable import IntentsAutomationCore

/// Read-only kernel observation of an owned /bin/sleep child; runs by default on macOS.
final class AutomationMacProcessInventoryLiveTests: XCTestCase {
    func testOwnedChildIsObservedWithKernelStartIdentityAndAbsentAfterReap() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let pid = child.processIdentifier
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        XCTAssertEqual(proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size), size)
        let start = "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"

        let observed = try AutomationMacProcessInventory.currentUser(watchedExecutablePaths: ["/bin/sleep"])
        try observed.validate(expectedUserID: getuid(), matchingExecutablePaths: ["/bin/sleep"])
        let record = try XCTUnwrap(observed.processes.first { $0.identity.pid == pid })
        XCTAssertEqual(record.executablePath, "/bin/sleep")
        XCTAssertEqual(record.userID, getuid())
        XCTAssertEqual(record.identity.startIdentity, start)

        child.terminate(); child.waitUntilExit()
        XCTAssertFalse(child.isRunning)
        let after = try AutomationMacProcessInventory.currentUser(watchedExecutablePaths: ["/bin/sleep"])
        XCTAssertFalse(after.processes.contains { $0.identity == record.identity })
    }
}
#endif
