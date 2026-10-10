import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationLegacyProductReadTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("original".utf8).write(to: root.appendingPathComponent("Fixture"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testNilAndVersionOneReadsBindToExpectedManifest() throws {
        let root = try fixture(), expected = try AutomationProductDigest.compute(bundle: root, version: nil)
        let versions: [Int?] = [nil, 1]
        for version in versions {
            XCTAssertEqual(try AutomationProductDigest.readFile(bundle: root, relativePath: "Fixture", maximumBytes: 8,
                version: version, expectedDigest: expected), Data("original".utf8))
            XCTAssertThrowsError(try AutomationProductDigest.readFile(bundle: root, relativePath: "Fixture", maximumBytes: 8,
                version: version, expectedDigest: String(repeating: "a", count: 64)))
        }
    }
    func testReadReplacementAndRestorationCannotReturnUnboundData() throws {
        let root = try fixture(), expected = try AutomationProductDigest.compute(bundle: root, version: nil)
        XCTAssertThrowsError(try AutomationProductDigest.readFile(bundle: root, relativePath: "Fixture", maximumBytes: 8,
            version: nil, expectedDigest: expected, stage: { phase in
                try Data((phase == .beforeRead ? "replaced" : "original").utf8).write(to: root.appendingPathComponent("Fixture"))
            })) { XCTAssertEqual($0 as? AutomationContractError, .conflictingOperation) }
    }
    func testOtherProductChangesDuringReadInvalidateTheManifest() throws {
        let root = try fixture(), expected = try AutomationProductDigest.compute(bundle: root, version: 1)
        XCTAssertThrowsError(try AutomationProductDigest.readFile(bundle: root, relativePath: "Fixture", maximumBytes: 8,
            version: 1, expectedDigest: expected, stage: { phase in
                if phase == .afterRead { try Data("new".utf8).write(to: root.appendingPathComponent("resource")) }
            })) { XCTAssertEqual($0 as? AutomationContractError, .conflictingOperation) }
    }
    func testUnboundLegacyReadKeepsItsExplicitWeakReadBehavior() throws {
        let root = try fixture()
        try Data("replaced".utf8).write(to: root.appendingPathComponent("Fixture"))
        XCTAssertEqual(try AutomationProductDigest.readFile(bundle: root, relativePath: "Fixture", maximumBytes: 8,
            version: nil), Data("replaced".utf8))
    }
}
