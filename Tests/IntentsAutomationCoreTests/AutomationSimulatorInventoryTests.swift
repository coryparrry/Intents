#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationSimulatorInventoryTests: XCTestCase {
    private let deviceID = "6F1E2D3C-4B5A-6978-8A9B-0C1D2E3F4A5B"
    private func read(_ payload: String, status: Int32 = 0, truncated: Bool = false,
                      duration: Duration = .seconds(600), deadline: ContinuousClock.Instant? = nil) async throws -> [AutomationSimulator] {
        try await AutomationSimulatorInventory.read(developerDirectory: URL(fileURLWithPath: "/private/tmp"),
            workspace: URL(fileURLWithPath: "/private/tmp"), maximumDuration: duration, absoluteDeadline: deadline, command: { executable, arguments, directory, environment, timeout, absoluteDeadline in
                XCTAssertEqual(executable.path, "/usr/bin/xcrun")
                XCTAssertEqual(arguments, ["simctl", "list", "devices", "available", "--json"])
                XCTAssertEqual(directory.path, "/private/tmp")
                XCTAssertEqual(environment, ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": "/private/tmp",
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "TMPDIR": NSTemporaryDirectory()])
                XCTAssertEqual(timeout, duration)
                XCTAssertEqual(absoluteDeadline, deadline)
                return .init(exitStatus: status, stdout: Data(payload.utf8), stderr: Data(), logsTruncated: truncated)
            })
    }
    func testBudgetedReadRetainsFreshExactDeviceStateAndFiltersOtherRuntimes() async throws {
        let payload = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-1":[
          {"isAvailable":true,"udid":"\(deviceID)","name":"Owned","state":"Booted"}],
          "com.apple.CoreSimulator.SimRuntime.iOS-26-0":[{"isAvailable":true,"udid":"old"}]}}
        """
        for duration in [Duration.seconds(60), .seconds(600), .milliseconds(250)] {
            let devices = try await read(payload, duration: duration, deadline: ContinuousClock.now.advanced(by: duration))
            XCTAssertEqual(devices, [.init(id: deviceID, name: "Owned", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1", state: "Booted")])
        }
    }
    func testFailedTruncatedMalformedAndIncompleteInventoryCannotAuthorizeDevice() async throws {
        let invalidDevice = "{\"devices\":{\"com.apple.CoreSimulator.SimRuntime.iOS-27-1\":[{\"isAvailable\":true,\"udid\":\"booted\",\"name\":\"Alias\",\"state\":\"Booted\"}]}}"
        let unavailableDevice = "{\"devices\":{\"com.apple.CoreSimulator.SimRuntime.iOS-27-1\":[{\"isAvailable\":false,\"udid\":\"\(deviceID)\",\"name\":\"Hidden\",\"state\":\"Shutdown\"}]}}"
        let missingState = "{\"devices\":{\"com.apple.CoreSimulator.SimRuntime.iOS-27-1\":[{\"isAvailable\":true,\"udid\":\"\(deviceID)\",\"name\":\"Owned\"}]}}"
        for (payload, status, truncated) in [("{}", Int32(1), false), ("{}", 0, true), ("", 0, false),
                                             ("{}", 0, false), (invalidDevice, 0, false), (missingState, 0, false), (unavailableDevice, 0, false)] {
            do { _ = try await read(payload, status: status, truncated: truncated); XCTFail("Accepted invalid inventory") }
            catch { }
        }
    }
    func testExpiredReadDoesNotLaunchQuery() async {
        do {
            _ = try await AutomationSimulatorInventory.read(developerDirectory: URL(fileURLWithPath: "/private/tmp"),
                workspace: URL(fileURLWithPath: "/private/tmp"), maximumDuration: .zero, command: { _, _, _, _, _, _ in
                    XCTFail("Expired inventory query launched")
                    throw AutomationContractError.invalidIdentity
                })
            XCTFail("Accepted expired inventory budget")
        } catch { XCTAssertEqual(error as? AutomationRPCError, .timedOut) }
    }
}
#endif
