#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

final class AutomationPhysicalDeviceInventoryTests: XCTestCase {
    private func entry(_ id: String = "00008140-000E4D803C0B001C", name: String = "iPhone", platform: String = "com.apple.platform.iphoneos", simulator: Bool = false, available: Bool = true) -> [String: Any] {
        ["identifier": id, "name": name, "modelName": "iPhone 16 Pro Max", "operatingSystemVersion": "27.2 (24B5089g)",
         "platform": platform, "simulator": simulator, "available": available, "ignored": false]
    }
    private func parse(_ entries: [[String: Any]]) throws -> [AutomationPhysicalDevice] {
        try AutomationPhysicalDeviceInventory.parse(JSONSerialization.data(withJSONObject: entries))
    }
    func testOnlyActualPhysicalIOSDevicesAreSelectable() throws {
        let result = try parse([entry(), entry("simulator", simulator: true), entry("mac", platform: "com.apple.platform.macosx"), entry("tv", platform: "com.apple.platform.appletvos")])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "00008140-000E4D803C0B001C")
        XCTAssertEqual(result[0].name, "iPhone")
        XCTAssertTrue(result[0].available)
    }
    func testSameNamedDevicesKeepDistinctIdentifiersAndStableOrder() throws {
        let first = "00008140-000E4D803C0B001C", second = "00008140-000E4D803C0B002C"
        let result = try parse([entry(second), entry(first)])
        XCTAssertEqual(result.map(\.id), [first, second])
        XCTAssertNotEqual(result[0].selectionLabel, result[1].selectionLabel)
    }
    func testUnavailableDeviceIsShownWithoutBecomingAvailable() throws {
        XCTAssertFalse(try parse([entry(available: false)])[0].available)
    }
    func testIgnoredDevicesAreExcluded() throws {
        var ignored = entry(); ignored["ignored"] = true
        XCTAssertTrue(try parse([ignored]).isEmpty)
    }
    func testMalformedInventoryDuplicateIdentityAndUnboundedInputAreRejected() throws {
        XCTAssertThrowsError(try parse([entry("iPhone")]))
        XCTAssertThrowsError(try parse([entry(), entry()]))
        XCTAssertThrowsError(try parse([entry(name: "iPhone\nOther")]))
        XCTAssertThrowsError(try parse([entry(name: String(repeating: "x", count: 257))]))
        XCTAssertThrowsError(try AutomationPhysicalDeviceInventory.parse(Data(repeating: 32, count: 2_097_153)))
        XCTAssertThrowsError(try AutomationPhysicalDeviceInventory.parse(Data("{}".utf8)))
        var malformed = entry(); malformed["available"] = "true"
        XCTAssertThrowsError(try parse([malformed]))
    }
    func testMissingOptionalPresentationFieldsRemainHonest() throws {
        var value = entry(); value.removeValue(forKey: "modelName"); value.removeValue(forKey: "operatingSystemVersion")
        let result = try parse([value])[0]
        XCTAssertEqual(result.model, "iPhone or iPad")
        XCTAssertEqual(result.operatingSystem, "Unknown version")
    }
    func testCoreDeviceDiscoveryMapsXcodeUDIDAndUUIDToOneLeaseIdentity() throws {
        let uuid = "1AD4F755-6F58-58E5-AC71-B1EDFECADA93", udid = "00008140-000E4D803C0B001C"
        let data = try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"],
            "result": ["devices": [["identifier": uuid.lowercased(), "hardwareProperties": ["udid": udid]]]]])
        let identifiers = try AutomationPhysicalDeviceInventory.parseCoreIdentifiers(data)
        XCTAssertEqual(identifiers[uuid.lowercased()], uuid)
        XCTAssertEqual(identifiers[udid.lowercased()], uuid)
        var target = TargetIdentity(id: udid, kind: .physical); target.physicalDeviceIdentifier = identifiers[udid.lowercased()]
        XCTAssertEqual(target.leaseKey, TargetIdentity(id: uuid, kind: .physical).leaseKey)
        XCTAssertEqual(target.id, udid, "Xcode destination must remain unchanged")
    }
    func testCoreDeviceDiscoveryRejectsAmbiguousAliasesAndFailedResults() throws {
        let udid = "00008140-000E4D803C0B001C"
        let data = try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"], "result": ["devices": [
            ["identifier": UUID().uuidString, "hardwareProperties": ["udid": udid]],
            ["identifier": UUID().uuidString, "hardwareProperties": ["udid": udid]]]]])
        XCTAssertThrowsError(try AutomationPhysicalDeviceInventory.parseCoreIdentifiers(data))
        XCTAssertThrowsError(try AutomationPhysicalDeviceInventory.parseCoreIdentifiers(Data("{\"info\":{\"outcome\":\"timeout\"}}".utf8)))
    }
}
#endif
