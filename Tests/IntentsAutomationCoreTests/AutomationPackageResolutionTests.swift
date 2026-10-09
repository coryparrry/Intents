import XCTest
@testable import IntentsAutomationCore

final class AutomationPackageResolutionTests: XCTestCase {
    private let revision = String(repeating: "a", count: 40)
    private func bytes(version: Int = 3, location: String = "https://example.invalid/Remote.git", identity: String = "remote", state: [String: String]? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": version, "originHash": String(repeating: "b", count: 64),
            "pins": [["identity": identity, "kind": "remoteSourceControl", "location": location, "state": state ?? ["revision": revision, "version": "1.2.3"]]]])
    }
    func testCurrentFormatsKeepCapturedPinsSeparateFromRequirementSatisfaction() throws {
        for version in [2, 3] {
            let index = try XCTUnwrap(AutomationPackageResolution.read(bytes(version: version)))
            let pin = try XCTUnwrap(index.pinsByIdentity["remote"])
            XCTAssertEqual(pin.location, "https://example.invalid/Remote.git")
            XCTAssertEqual(AutomationPackageResolution.requirementState(["kind": "revision", "revision": revision], pin: pin), "satisfied")
            XCTAssertEqual(AutomationPackageResolution.requirementState(["kind": "exactVersion", "version": "1.2.3"], pin: pin), "satisfied")
            XCTAssertEqual(AutomationPackageResolution.requirementState(["kind": "exactVersion", "version": "1.2.4"], pin: pin), "mismatch")
            XCTAssertEqual(AutomationPackageResolution.requirementState(["kind": "upToNextMajorVersion", "minimumVersion": "1.2.3"], pin: pin), "unresolved")
        }
        let pin = try XCTUnwrap(AutomationPackageResolution.read(bytes(state: ["revision": revision, "branch": "feature/demo"]))?.pinsByIdentity["remote"])
        XCTAssertEqual(AutomationPackageResolution.requirementState(["kind": "branch", "branch": "feature/demo"], pin: pin), "satisfied")
        XCTAssertEqual(AutomationPackageResolution.requirementState(["kind": "branch", "branch": "other"], pin: pin), "mismatch")
    }
    func testUnsafeLocationsMalformedAndAmbiguousMetadataAreUnavailable() throws {
        for location in ["https://token@example.invalid/Remote.git", "https://example.invalid/Remote.git?token=secret", "https://example.invalid/Remote.git#secret", "ssh://example.invalid/Remote.git", "https://example.invalid/Remote%2egit"] {
            XCTAssertNil(try AutomationPackageResolution.read(bytes(location: location)))
        }
        XCTAssertNil(try AutomationPackageResolution.read(bytes(identity: "wrong")))
        XCTAssertNil(try AutomationPackageResolution.read(bytes(version: 1)))
        XCTAssertNil(try AutomationPackageResolution.read(bytes(state: ["revision": "HEAD"])))
        XCTAssertNil(try AutomationPackageResolution.read(bytes(state: ["revision": revision, "version": "1.2.3", "branch": "main"])))
        let good = String(decoding: try bytes(), as: UTF8.self)
        XCTAssertNil(try AutomationPackageResolution.read(Data((good + "{}").utf8)))
        XCTAssertNil(try AutomationPackageResolution.read(Data(good.replacingOccurrences(of: "\"version\":3", with: "\"version\":3,\"version\":2").utf8)))
        XCTAssertNil(try AutomationPackageResolution.read(Data("{\"version\":3,\"ver\\u0073ion\":2,\"pins\":[]}".utf8)))
        var duplicate = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes()) as? [String: Any])
        let pins = try XCTUnwrap(duplicate["pins"] as? [[String: Any]]); duplicate["pins"] = pins + pins
        XCTAssertNil(try AutomationPackageResolution.read(JSONSerialization.data(withJSONObject: duplicate)))
    }
    func testBudgetsAndRepositoryResolutionFormat() throws {
        XCTAssertNil(try AutomationPackageResolution.read(Data(repeating: 32, count: 1_048_577)))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("FoundationEvals/FoundationEvals.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"))
        let index = try XCTUnwrap(AutomationPackageResolution.read(data))
        XCTAssertNotNil(index.pinsByIdentity["coreai-models"]); XCTAssertNotNil(index.pinsByIdentity["sparkle"])
        XCTAssertFalse(index.record.pins.isEmpty)
    }
    func testMalformedVersionsAndBranchesCannotSatisfyRequirements() throws {
        let base = try XCTUnwrap(AutomationPackageResolution.read(bytes())?.pinsByIdentity["remote"])
        for version in ["", "+build", "1.2.3-.", "1.2.3-alpha..beta", "01.2.3", "1.2.3-01", "1.2.3+", "1.2.3+build..one"] {
            XCTAssertNil(try AutomationPackageResolution.read(bytes(state: ["revision": revision, "version": version])))
            XCTAssertEqual(AutomationPackageResolution.requirementState(["kind": "exactVersion", "version": version], pin: base), "unresolved")
        }
        for version in ["0.0.0", "1.2.3-alpha.1+build.01", "1.2.3--alpha"] {
            let pin = try XCTUnwrap(AutomationPackageResolution.read(bytes(state: ["revision": revision, "version": version]))?.pinsByIdentity["remote"])
            XCTAssertEqual(AutomationPackageResolution.requirementState(["kind": "exactVersion", "version": version], pin: pin), "satisfied")
        }
        for branch in ["feature..demo", "/main", "main/", "main.lock", "feature/.hidden", "-main", "main.", "feature//demo"] {
            XCTAssertNil(try AutomationPackageResolution.read(bytes(state: ["revision": revision, "branch": branch])))
            XCTAssertEqual(AutomationPackageResolution.requirementState(["kind": "branch", "branch": branch], pin: base), "unresolved")
        }
    }
}
