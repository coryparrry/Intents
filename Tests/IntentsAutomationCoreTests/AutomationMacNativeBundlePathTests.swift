#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

final class AutomationMacNativeBundlePathTests: XCTestCase {
    private func fixture() throws -> (URL, URL) {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("mac-path-" + UUID().uuidString)
        let selected = root.appendingPathComponent("Selected.app"), other = root.appendingPathComponent("Other.app")
        for path in [selected, other] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (selected, other)
    }
    func testFoundationAliasRoundTripKeepsTheApprovedIdentity() throws {
        let (selected, _) = try fixture()
        let path = try AutomationMacNativeBundlePath(canonical: selected)
        let owner = AutomationJSON.object(["canonicalBundlePath": .string(selected.path), "pid": .number(42), "processStartIdentity": .string("100:0")])
        let helper = try path.forHelper(owner)
        XCTAssertEqual(helper.object?["canonicalBundlePath"], .string(selected.resolvingSymlinksInPath().path))
        XCTAssertEqual(try path.forOwner(helper), owner)
        XCTAssertEqual(try AutomationPath.canonical(path.helper).path, selected.path)
    }
    func testDifferentBundleOrReplyPathIsRejected() throws {
        let (selected, other) = try fixture()
        XCTAssertThrowsError(try AutomationMacNativeBundlePath(canonical: selected, helper: other))
        let path = try AutomationMacNativeBundlePath(canonical: selected)
        XCTAssertThrowsError(try path.forOwner(.object(["canonicalBundlePath": .string(other.path)])))
    }
    func testAliasReplacementCannotRetargetAnApprovedBundle() throws {
        let (selected, other) = try fixture(), alias = selected.deletingLastPathComponent().appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: selected)
        let path = try AutomationMacNativeBundlePath(canonical: selected, helper: alias)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: other)
        XCTAssertThrowsError(try path.forHelper(.object(["canonicalBundlePath": .string(selected.path)])))
    }
}
#endif
