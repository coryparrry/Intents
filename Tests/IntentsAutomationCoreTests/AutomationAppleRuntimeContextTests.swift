import XCTest
@testable import IntentsAutomationCore

final class AutomationAppleRuntimeContextTests: XCTestCase {
    private let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: 1)
    private let program = AutomationHostProgram(operations: [.init(id: "probe", kind: .invoke, typeID: "Probe", resultCodec: "noValue")])
    private var observation: [String: Any] {
        ["processOSVersion": "Version 27.0", "processOSBuild": "26A425", "architecture": "arm64",
         "sdkPlatform": "macosx", "xcodeBuild": "27A266a", "sdkBuild": "26A425",
         "frameworkPath": "/owned/Xcode/Frameworks/AppIntentsTesting.framework/AppIntentsTesting",
         "frameworkSHA256": String(repeating: "a", count: 64), "frameworkUUID": String(repeating: "b", count: 32),
         "frameworkCPUType": UInt32(0x0100000c), "frameworkCPUSubtype": 0]
    }
    private func receipt(version: Int, context: [String: Any]? = nil) -> [String: Any] {
        var fields: [String: Any] = ["schemaVersion": version, "runner": ["pid": 123, "startIdentity": "123:0", "executablePath": "/owned/Host"],
            "runID": scope.runId, "attemptID": scope.attemptId, "segmentID": scope.segmentId, "leaseGeneration": 1,
            "bundleID": "example.Subject", "productDigest": "product", "operations": [["operationID": "probe", "dispatched": true, "value": ["kind": "noValue"]]], "complete": true]
        fields["runtimeContext"] = context
        return fields
    }
    private func read(_ fields: [String: Any], platform: String = "macos") throws -> AutomationImportedHostReceipt {
        try AutomationHostReceiptImporter.importReceipt(JSONSerialization.data(withJSONObject: fields), scope: scope,
            app: .init(logicalID: "subject", bundleID: "example.Subject", platform: platform, productDigest: "product"), program: program)
    }
    func testLegacyAndMissingContextReceiptsRemainTypedWithoutAuthority() throws {
        for version in [2, 3] {
            let imported = try read(receipt(version: version))
            XCTAssertEqual(imported.values["probe"], .omission); XCTAssertNil(imported.runtimeObservation)
        }
        XCTAssertNil(try read(receipt(version: 2), platform: "ios").runtimeObservation)
        XCTAssertThrowsError(try read(receipt(version: 2, context: observation)))
        XCTAssertThrowsError(try read(receipt(version: 3), platform: "ios"))
        XCTAssertThrowsError(try read(receipt(version: 3, context: observation), platform: "ios"))
    }
    func testMacV3CarriesObservationWithoutCreatingACapability() throws {
        let imported = try read(receipt(version: 3, context: observation))
        let raw = try XCTUnwrap(imported.runtimeObservation)
        XCTAssertEqual(raw.frameworkCPUType, 0x0100000c); XCTAssertEqual(raw.frameworkUUID, String(repeating: "b", count: 32))
        XCTAssertEqual(imported.values["probe"], .omission)
    }
    func testMalformedObservationFailsClosed() throws {
        var variants: [[String: Any]] = []
        for key in observation.keys { var fields = observation; fields.removeValue(forKey: key); variants.append(fields) }
        for (key, value) in [("unknown", "extra"), ("frameworkUUID", "not-a-uuid"), ("frameworkSHA256", String(repeating: "A", count: 64)),
                             ("sdkPlatform", "iphonesimulator"), ("architecture", "x86_64"), ("frameworkPath", "relative"),
                             ("xcodeBuild", "build\nspoof"), ("processOSBuild", "")] {
            var fields = observation; fields[key] = value; variants.append(fields)
        }
        for value in [-1.0, 1.25, Double(UInt32.max) + 1] { var fields = observation; fields["frameworkCPUSubtype"] = value; variants.append(fields) }
        for fields in variants { XCTAssertThrowsError(try read(receipt(version: 3, context: fields))) }
        var wrongScope = receipt(version: 3, context: observation); wrongScope["attemptID"] = "old"
        XCTAssertThrowsError(try read(wrongScope))
        var incomplete = receipt(version: 3, context: observation); incomplete["complete"] = false
        XCTAssertThrowsError(try read(incomplete))
    }
    private func thin(cpu: UInt32 = 0x0100000c, subtype: UInt32 = 0, uuid: UInt8 = 1) -> Data {
        var data = Data(repeating: 0, count: 56)
        for (offset, value) in [(0, UInt32(0xfeedfacf)), (4, cpu), (8, subtype), (16, 1), (20, 24), (32, 0x1b), (36, 24)] {
            put(value, into: &data, at: offset)
        }
        data.replaceSubrange(40..<56, with: repeatElement(uuid, count: 16)); return data
    }
    private func put(_ value: UInt32, into data: inout Data, at offset: Int, big: Bool = false) {
        var word = big ? value.bigEndian : value.littleEndian
        withUnsafeBytes(of: &word) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
    }
    private func fat(wide: Bool) -> Data {
        let slices = [thin(), thin(subtype: 2, uuid: 2)], stride = wide ? 32 : 20, start = 8 + 2 * (wide ? 32 : 20)
        var data = Data(repeating: 0, count: start)
        put(wide ? 0xcafebabf : 0xcafebabe, into: &data, at: 0, big: true); put(2, into: &data, at: 4, big: true)
        for index in 0..<2 {
            let base = 8 + index * stride
            put(0x0100000c, into: &data, at: base, big: true); put(index == 0 ? 0 : 2, into: &data, at: base + 4, big: true)
            put(UInt32(start + index * 56), into: &data, at: base + (wide ? 12 : 8), big: true)
            put(56, into: &data, at: base + (wide ? 20 : 12), big: true)
            data.append(slices[index])
        }
        return data
    }
    func testThinAndUniversalImagesRetainExactUUIDCPUAndSubtype() throws {
        XCTAssertEqual(try AutomationMachOLoadedImageIdentity.images(in: thin()), [.init(uuid: String(repeating: "01", count: 16), cpu: 0x0100000c, subtype: 0)])
        for wide in [false, true] {
            let images = try AutomationMachOLoadedImageIdentity.images(in: fat(wide: wide))
            XCTAssertEqual(images.map(\.subtype), [0, 2]); XCTAssertEqual(images.map(\.uuid), [String(repeating: "01", count: 16), String(repeating: "02", count: 16)])
        }
        XCTAssertEqual(try AutomationMachOLoadedImageIdentity.images(in: thin(cpu: 0x01000007)).first?.cpu, 0x01000007)
    }
    func testMalformedLoadCommandsAndFatSlicesAreRejected() {
        var variants: [Data] = [Data(), thin().prefix(31)]
        for (offset, value) in [(16, UInt32(4097)), (20, 1_048_577), (36, 0), (36, 16), (36, 32), (32, 0)] {
            var data = thin(); put(value, into: &data, at: offset); variants.append(data)
        }
        var duplicate = thin(); duplicate.append(duplicate.subdata(in: 32..<56))
        put(2, into: &duplicate, at: 16); put(48, into: &duplicate, at: 20); variants.append(duplicate)
        for (offset, value) in [(4, UInt32(33)), (16, 0), (20, UInt32.max), (24, 31), (32, 0), (36, 48), (36, UInt32.max)] {
            var data = fat(wide: false); put(value, into: &data, at: offset, big: true); variants.append(data)
        }
        for data in variants { XCTAssertThrowsError(try AutomationMachOLoadedImageIdentity.images(in: data)) }
    }
    #if os(macOS)
    func testSelectedFrameworkCanBeParsedWithoutRunningOrQualifyingIt() throws {
        let path = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks/AppIntentsTesting.framework/Versions/A/AppIntentsTesting"
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("Selected Xcode framework unavailable") }
        let images = try AutomationMachOLoadedImageIdentity.images(in: AutomationReadOnlyFile.read(URL(fileURLWithPath: path), maximumBytes: 134_217_728))
        XCTAssertFalse(images.isEmpty); XCTAssertTrue(images.allSatisfy { $0.uuid.count == 32 })
    }
    func testImportedLabelsAndForeignFrameworkCannotPassIndependentSnapshotChecks() throws {
        let raw = try XCTUnwrap(read(receipt(version: 3, context: observation)).runtimeObservation)
        var app = AppIdentity(logicalID: "subject", bundleID: "example.Subject", platform: "macos", productDigest: "digest"); app.productDigestVersion = 2
        let host = AutomationPreparedAppleHost(app: app, target: .init(id: "fake", kind: .nativeMac, loginSession: "fake"),
            xctestrunPath: "/private/tmp/fake", xctestrunDigest: "digest", subjectProductPath: "/private/tmp/Subject.app", hostBundlePath: "/private/tmp/Host.app",
            hostProductDigest: "digest", hostBundleID: "example.Host", testTarget: "Host", hostProductDigestVersion: 2)
        XCTAssertThrowsError(try AutomationMacAppleRuntimeSnapshot.observe(host: host, developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"), observation: raw))
    }
    #endif
}
