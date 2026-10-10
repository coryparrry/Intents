import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationPhysicalInventoryTests: XCTestCase {
    private let target = "00008140-000E4D803C0B001C"
    private let device = "1AD4F755-6F58-58E5-AC71-B1EDFECADA93"
    private let bundle = "com.example.Tests.xctrunner"
    private let runnerName = "Tests-Runner"

    func testCurrentInspectionRequiresItsExactOutputFile() throws {
        let data = try processData([]), expected = URL(fileURLWithPath: "/private/tmp/inspection.json")
        XCTAssertNoThrow(try AutomationPhysicalProcessInventory.parse(data, targetID: target, expectedOutputURL: expected))
        XCTAssertThrowsError(try AutomationPhysicalProcessInventory.parse(data, targetID: target,
            expectedOutputURL: URL(fileURLWithPath: "/private/tmp/another-inspection.json")))
        var root = base(command: "apps")
        root["result"] = ["deviceIdentifier": device, "apps": [], "defaultAppsIncluded": true,
                          "hiddenAppsIncluded": true, "internalAppsIncluded": true, "removableAppsIncluded": true]
        let apps = try JSONSerialization.data(withJSONObject: root)
        XCTAssertNoThrow(try AutomationPhysicalAppInventory.parse(apps, targetID: target, expectedOutputURL: expected))
        XCTAssertThrowsError(try AutomationPhysicalAppInventory.parse(apps, targetID: target,
            expectedOutputURL: URL(fileURLWithPath: "/private/tmp/another-inspection.json")))
    }

    func testControllerBundleValidationRejectsUnderscoresConsistently() throws {
        let apps = try appInventory(), processes = try processInventory([])
        XCTAssertThrowsError(try processes.runnerAbsent(bundleID: "example.Invalid_Runner", executableName: runnerName, ownedPID: nil, apps: apps))
    }

    func testControllerExecutablePathAcceptsOnlyOwnedContainerLayout() {
        let container = UUID().uuidString, owned = "Tests-Runner.app", longName = String(repeating: "a", count: 4097)
        for prefix in ["/private/var/containers/Bundle/Application/", "/var/containers/Bundle/Application/"] {
            XCTAssertTrue(AutomationPhysicalControllerValidation.matchesExecutablePath(
                prefix + container + "/" + owned + "/" + runnerName, bundleName: owned, executableName: runnerName), prefix)
        }
        let base = "/private/var/containers/Bundle/Application/" + container + "/"
        let rejected: [(String, String, String, String)] = [
            ("foreign-prefix", "/private/Apps/" + container + "/" + owned + "/" + runnerName, owned, runnerName),
            ("data-container", "/private/var/containers/Data/Application/" + container + "/" + owned + "/" + runnerName, owned, runnerName),
            ("relative-prefix", "private/var/containers/Bundle/Application/" + container + "/" + owned + "/" + runnerName, owned, runnerName),
            ("non-uuid-container", "/private/var/containers/Bundle/Application/fixture/" + owned + "/" + runnerName, owned, runnerName),
            ("empty-container", "/private/var/containers/Bundle/Application//" + owned + "/" + runnerName, owned, runnerName),
            ("nested-component", base + owned + "/Frameworks/" + runnerName, owned, runnerName),
            ("trailing-slash", base + owned + "/" + runnerName + "/", owned, runnerName),
            ("missing-executable", base + owned, owned, runnerName),
            ("bundle-mismatch", base + "Other.app/" + runnerName, owned, runnerName),
            ("executable-mismatch", base + owned + "/Other", owned, runnerName),
            ("dot-names", base + "./.", ".", "."),
            ("dot-dot-names", base + "../..", "..", ".."),
            ("dot-bundle", base + "./" + runnerName, ".", runnerName),
            ("dot-dot-executable", base + owned + "/..", owned, ".."),
            ("empty-names", base + "/", "", ""),
            ("nul-byte", base + owned + "/" + runnerName + "\0", owned, runnerName + "\0"),
            ("over-length", base + owned + "/" + longName, owned, longName),
            ("bundle-slash", base + owned + "/Nested/" + runnerName, owned + "/Nested", runnerName),
            ("executable-slash", base + owned + "/Nested/" + runnerName, owned, "Nested/" + runnerName),
        ]
        for (label, path, bundleName, executableName) in rejected {
            XCTAssertFalse(AutomationPhysicalControllerValidation.matchesExecutablePath(path, bundleName: bundleName, executableName: executableName), label)
        }
    }

    func testCompleteBoundInventoryProvesOnlyCurrentAbsence() throws {
        let apps = try appInventory()
        let absent = try processInventory([])
        XCTAssertTrue(try absent.runnerAbsent(bundleID: bundle, executableName: runnerName, ownedPID: 42, apps: apps))
        let present = try processInventory([["processIdentifier": 42, "executable": "file:///private/Apps/Tests-Runner.app/Tests-Runner"]])
        XCTAssertFalse(try present.runnerAbsent(bundleID: bundle, executableName: runnerName, ownedPID: 42, apps: apps))
        XCTAssertFalse(try present.runnerAbsent(bundleID: bundle, executableName: runnerName, ownedPID: nil, apps: apps))
    }

    func testReusedPIDAndAmbiguousSameNameRemainUnproved() throws {
        let apps = try appInventory()
        let reused = try processInventory([["processIdentifier": 42, "executable": "file:///private/Other.app/Other"]])
        XCTAssertFalse(try reused.runnerAbsent(bundleID: bundle, executableName: runnerName, ownedPID: 42, apps: apps))
        let sameName = try processInventory([["processIdentifier": 99, "executable": "file:///private/Other.app/Tests-Runner"]])
        XCTAssertFalse(try sameName.runnerAbsent(bundleID: bundle, executableName: runnerName, ownedPID: nil, apps: apps))
        let renamed = try processInventory([["processIdentifier": 99, "executable": "file:///private/Apps/Tests-Runner.app/Child"]])
        XCTAssertFalse(try renamed.runnerAbsent(bundleID: bundle, executableName: runnerName, ownedPID: nil, apps: apps))
    }

    func testRejectsMalformedFailedFilteredForeignAndIncompleteInventories() throws {
        let data = try processData([])
        XCTAssertThrowsError(try AutomationPhysicalProcessInventory.parse(Data(data.dropLast()), targetID: target))
        XCTAssertThrowsError(try AutomationPhysicalProcessInventory.parse(data, targetID: "another-device"))
        for change in ["failure", "filtered", "filtered-equals", "unknown-option", "duplicate-device", "version", "empty", "duplicate", "wrong-command", "invalid-url"] {
            var root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            var info = root["info"] as! [String: Any], result = root["result"] as! [String: Any]
            switch change {
            case "failure": info["outcome"] = "failure"
            case "filtered": info["arguments"] = (info["arguments"] as! [String]) + ["--filter", "foo"]
            case "filtered-equals": info["arguments"] = (info["arguments"] as! [String]) + ["--filter=foo"]
            case "unknown-option": info["arguments"] = (info["arguments"] as! [String]) + ["--include-processes=launchd"]
            case "duplicate-device": info["arguments"] = (info["arguments"] as! [String]) + ["--device", target]
            case "version": info["jsonVersion"] = 6
            case "empty": result["runningProcesses"] = []
            case "duplicate": result["runningProcesses"] = [["processIdentifier": 1, "executable": "file:///sbin/launchd"], ["processIdentifier": 1, "executable": "file:///sbin/launchd"]]
            case "wrong-command": info["commandType"] = "devicectl.device.info.apps"
            default: result["runningProcesses"] = [["processIdentifier": 1, "executable": "file:///sbin/../sbin/launchd"]]
            }
            root["info"] = info; root["result"] = result
            XCTAssertThrowsError(try AutomationPhysicalProcessInventory.parse(JSONSerialization.data(withJSONObject: root), targetID: target), change)
        }
    }

    func testAppInventoryMustBeCompleteUniqueAndOnSameDevice() throws {
        var root = base(command: "apps")
        root["result"] = ["deviceIdentifier": device, "apps": [], "defaultAppsIncluded": true,
                          "hiddenAppsIncluded": true, "internalAppsIncluded": true, "removableAppsIncluded": false]
        XCTAssertThrowsError(try AutomationPhysicalAppInventory.parse(JSONSerialization.data(withJSONObject: root), targetID: target))
        let foreign = try appInventory(device: UUID().uuidString)
        XCTAssertThrowsError(try processInventory([]).runnerAbsent(bundleID: bundle, executableName: runnerName, ownedPID: nil, apps: foreign))
    }

    private func processInventory(_ extra: [[String: Any]]) throws -> AutomationPhysicalProcessInventory {
        try .parse(processData(extra), targetID: target)
    }
    private func processData(_ extra: [[String: Any]]) throws -> Data {
        var root = base(command: "processes")
        root["result"] = ["deviceIdentifier": device, "runningProcesses": [["processIdentifier": 1, "executable": "file:///sbin/launchd"]] + extra]
        return try JSONSerialization.data(withJSONObject: root)
    }
    private func appInventory(device: String? = nil) throws -> AutomationPhysicalAppInventory {
        var root = base(command: "apps")
        root["result"] = ["deviceIdentifier": device ?? self.device,
                          "apps": [["bundleIdentifier": bundle, "url": "file:///private/Apps/Tests-Runner.app/"]],
                          "defaultAppsIncluded": true, "hiddenAppsIncluded": true, "internalAppsIncluded": true, "removableAppsIncluded": true]
        return try .parse(JSONSerialization.data(withJSONObject: root), targetID: target)
    }
    private func base(command: String) -> [String: Any] {
        ["info": ["outcome": "success", "jsonVersion": 5, "commandType": "devicectl.device.info." + command,
                  "arguments": ["devicectl", "device", "info", command, "--device", target]
                    + (command == "apps" ? ["--include-all-apps"] : [])
                    + ["--json-output", "/private/tmp/inspection.json", "--timeout", "10", "--quiet"]]]
    }
}
