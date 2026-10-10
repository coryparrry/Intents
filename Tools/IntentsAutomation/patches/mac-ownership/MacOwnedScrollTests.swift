import Foundation
import XCTest
@testable import AgentDeviceMacOSHelper

final class MacOwnedScrollTests: XCTestCase {
  private func fixture() throws -> (URL, MacApplicationTarget) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString + ".app")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "example.Target", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
      .write(to: root.appendingPathComponent("Contents/Info.plist"))
    return (root, .init(bundleId: "example.Target", canonicalBundlePath: root.path, pid: 12, processStartIdentity: "1:0"))
  }
  func testDirectionsHaveSmallSignedDeltasAndReceiptIsUnconfirmed() throws {
    let (root, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    for (direction, vertical, horizontal) in [("up", 40, 0), ("down", -40, 0), ("left", 0, 40), ("right", 0, -40)] {
      var checks = 0, recipients: [MacApplicationTarget] = []
      let request = MacOwnedScrollRequest(x: 10, y: 20, direction: direction)
      let receipt = try MacOwnedScrollDelivery<MacOwnedScrollRequest>(prepare: { $0 }, verify: { _, _ in checks += 1 },
        submit: { event, recipient in XCTAssertEqual(event.vertical, Int32(vertical)); XCTAssertEqual(event.horizontal, Int32(horizontal)); recipients.append(recipient) })
        .scroll(request, target: target)
      XCTAssertEqual(checks, 2); XCTAssertEqual(recipients, [target]); XCTAssertEqual(receipt.disposition, "submittedUnconfirmed")
      XCTAssertEqual(receipt.direction, direction)
    }
  }
  func testInvalidBoundsCreationAndFreshOwnershipFailureNeverSubmit() throws {
    let (root, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    var submitted = 0, checks = 0
    let delivery = MacOwnedScrollDelivery<Int>(prepare: { _ in 1 }, verify: { _, _ in
      checks += 1; if checks == 2 { throw HelperError.commandFailed("changed after creation") }
    }, submit: { _, _ in submitted += 1 })
    for request in [MacOwnedScrollRequest(x: .nan, y: 0, direction: "down"), .init(x: 0, y: 0, direction: "other"), .init(x: 1_000_001, y: 0, direction: "up")] {
      XCTAssertThrowsError(try delivery.scroll(request, target: target))
    }
    XCTAssertThrowsError(try delivery.scroll(.init(x: 1, y: 2, direction: "down"), target: target))
    XCTAssertEqual(submitted, 0)
    let failedCreation = MacOwnedScrollDelivery<Int>(prepare: { _ in throw HelperError.commandFailed("create failed") },
      verify: { _, _ in }, submit: { _, _ in submitted += 1 })
    XCTAssertThrowsError(try failedCreation.scroll(.init(x: 1, y: 2, direction: "up"), target: target)); XCTAssertEqual(submitted, 0)
  }
  func testSubmissionFailureIsUnknownAndNeverRetries() throws {
    let (root, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    var calls = 0
    let delivery = MacOwnedScrollDelivery<Int>(prepare: { _ in 1 }, verify: { _, _ in }, submit: { _, _ in calls += 1; throw HelperError.commandFailed("lost") })
    do { _ = try delivery.scroll(.init(x: 1, y: 2, direction: "down"), target: target); XCTFail() }
    catch HelperError.commandFailed(let message, let details) {
      XCTAssertEqual(message, "exact-process scroll delivery is unknown"); XCTAssertEqual(details["mayHaveCommitted"], "true")
    }
    XCTAssertEqual(calls, 1)
  }
  func testStrictArgumentsRequireExactTargetAndRejectDuplicatesAndLegacyOptions() throws {
    let (root, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let args = ["--x", "1", "--y", "2", "--direction", "down", "--surface", "frontmost-app", "--bundle-id", target.bundleId,
      "--target-pid", "12", "--target-process-start", "1:0", "--target-bundle-path", target.canonicalBundlePath]
    let parsed = try MacOwnedScrollRequest.from(args); XCTAssertEqual(parsed.1, target)
    XCTAssertThrowsError(try MacOwnedScrollRequest.from(args + ["--direction", "up"]))
    XCTAssertThrowsError(try MacOwnedScrollRequest.from(args + ["--pixels", "100000"]))
    XCTAssertThrowsError(try MacOwnedScrollRequest.from(Array(args.prefix(10))))
  }
  func testSecureUnknownAndInheritedTextContentIsSuppressedBeforeSnapshot() {
    for role in ["AXTextField", "AXTextArea"] {
      XCTAssertTrue(MacSnapshotDisclosure.suppressContent(role: role, subrole: nil, inherited: false))
      XCTAssertTrue(MacSnapshotDisclosure.suppressContent(role: role, subrole: "AXSecureTextField", inherited: false))
    }
    XCTAssertTrue(MacSnapshotDisclosure.suppressContent(role: "AXStaticText", subrole: nil, inherited: true))
    XCTAssertFalse(MacSnapshotDisclosure.suppressContent(role: "AXButton", subrole: nil, inherited: false))
    XCTAssertFalse(MacSnapshotDisclosure.suppressContent(role: "AXTextField", subrole: "AXSearchField", inherited: false))
  }
  func testSuppressedUntitledWindowNeverReadsOrSerializesSensitiveTitle() throws {
    var sensitiveReads = 0
    let title = MacSnapshotDisclosure.content(suppressed: true) { sensitiveReads += 1; return "synthetic-secret-sentinel" }
    XCTAssertNil(title); XCTAssertEqual(sensitiveReads, 0)
    let json = try JSONSerialization.data(withJSONObject: ["windowTitle": title as Any? ?? NSNull()])
    XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("synthetic-secret-sentinel"))
  }
  func testSharedNodeRevisitedUnderProtectedAncestryCannotProduceAResponse() throws {
    var emitted = false
    XCTAssertThrowsError(try {
      try MacSnapshotDisclosure.requireSafeGraph(restrictedRevisit: true)
      emitted = true
    }())
    XCTAssertFalse(emitted)
    XCTAssertNoThrow(try MacSnapshotDisclosure.requireSafeGraph(restrictedRevisit: false))
    XCTAssertThrowsError(try MacSnapshotDisclosure.requireSafeGraph(restrictedRevisit: false, truncated: true))
  }
}
