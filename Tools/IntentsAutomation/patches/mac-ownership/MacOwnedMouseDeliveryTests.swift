import AgentDeviceMacOSInput
import Foundation
import XCTest
@testable import AgentDeviceMacOSHelper

final class MacOwnedMouseDeliveryTests: XCTestCase {
  private func fixture() throws -> (URL, MacApplicationTarget) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
      .appendingPathComponent("mac-input-" + UUID().uuidString + ".app")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "example.Target", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
    try data.write(to: root.appendingPathComponent("Contents/Info.plist"))
    return (root, .init(bundleId: "example.Target", canonicalBundlePath: root.path, pid: 12, processStartIdentity: "1:0"))
  }
  private final class Backend {
    var events: [MacOwnedMouseEvent] = []
    var targets: [MacApplicationTarget] = []
    var isCancelled = false, changedProcess = false, changedFrontmost = false
    var creationFailure = false, failDown = false, failUp = false
    var duringWait: (() -> Void)?
    func delivery() -> MacOwnedMouseDelivery<MacOwnedMouseEvent> {
      .init(prepare: { event in
        if self.creationFailure { throw HelperError.commandFailed("creation failed") }
        return event
      }, submit: { event, target in
        self.events.append(event); self.targets.append(target)
        if self.failDown && event.type == .leftMouseDown { throw HelperError.commandFailed("unknown down result") }
        if self.failUp && event.type == .leftMouseUp { throw HelperError.commandFailed("unknown up result") }
      }, verifyTarget: { _ in
        if self.changedProcess || self.changedFrontmost { throw HelperError.commandFailed("target changed") }
      }, verifyReleaseTarget: { _ in
        if self.changedProcess { throw HelperError.commandFailed("PID reused") }
      }, cancelled: { self.isCancelled }, wait: { _ in self.duringWait?() })
    }
  }
  private func assertUnknown(_ body: () throws -> Void, released: Bool, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try body(), file: file, line: line) { error in
      guard case HelperError.commandFailed(_, let details) = error else { return XCTFail("Expected unknown delivery", file: file, line: line) }
      XCTAssertEqual(details["deliveryUnknown"], "true", file: file, line: line)
      XCTAssertEqual(details["mayHaveCommitted"], "true", file: file, line: line)
      XCTAssertEqual(details["releaseSubmitted"], String(released), file: file, line: line)
    }
  }
  func testExactRecipientReceivesEveryPairAndSuccessRemainsUnconfirmed() throws {
    let (root, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let backend = Backend()
    let receipt = try backend.delivery().press(.init(x: 10, y: -20, clicks: 2, doubleClick: true), target: target)
    XCTAssertEqual(receipt.disposition, "submittedUnconfirmed"); XCTAssertTrue(receipt.releaseSubmitted)
    XCTAssertEqual(receipt.x, 10); XCTAssertEqual(receipt.y, -20)
    XCTAssertEqual(backend.events.map(\.type), [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
    XCTAssertTrue(backend.targets.allSatisfy { $0 == target })
    XCTAssertEqual(backend.events.filter { $0.type == .leftMouseDown }.map(\.clickState), [1, 2, 1, 2])
  }
  func testCancellationOrCreationFailureBeforeSubmissionPostsNothing() throws {
    let (root, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    for cancel in [true, false] {
      let backend = Backend(); backend.isCancelled = cancel; backend.creationFailure = !cancel
      XCTAssertThrowsError(try backend.delivery().press(.init(x: 1, y: 2), target: target))
      XCTAssertTrue(backend.events.isEmpty)
    }
  }
  func testCancellationDuringHoldSubmitsReleaseOnlyToOriginalRecipient() throws {
    let (root, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let backend = Backend(); backend.duringWait = { backend.isCancelled = true }
    assertUnknown({ _ = try backend.delivery().press(.init(x: 1, y: 2, clicks: 3), target: target) }, released: true)
    XCTAssertEqual(backend.events.map(\.type), [.mouseMoved, .leftMouseDown, .leftMouseUp])
    XCTAssertTrue(backend.targets.allSatisfy { $0 == target })
  }
  func testFrontmostChangeAllowsOriginalRecipientReleaseButNoFurtherDown() throws {
    let (root, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let backend = Backend(); backend.duringWait = { backend.changedFrontmost = true }
    assertUnknown({ _ = try backend.delivery().press(.init(x: 1, y: 2, clicks: 3), target: target) }, released: true)
    XCTAssertEqual(backend.events.map(\.type), [.mouseMoved, .leftMouseDown, .leftMouseUp])
  }
  func testReusedPIDNeverReceivesCleanupRelease() throws {
    let (root, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let backend = Backend(); backend.duringWait = { backend.changedProcess = true }
    assertUnknown({ _ = try backend.delivery().press(.init(x: 1, y: 2), target: target) }, released: false)
    XCTAssertEqual(backend.events.map(\.type), [.mouseMoved, .leftMouseDown])
  }
  func testUnknownDownSubmissionGetsStructuredCleanupWithoutRetry() throws {
    let (root, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let backend = Backend(); backend.failDown = true
    assertUnknown({ _ = try backend.delivery().press(.init(x: 1, y: 2), target: target) }, released: true)
    XCTAssertEqual(backend.events.map(\.type), [.mouseMoved, .leftMouseDown, .leftMouseUp])
  }
  func testUnknownReleaseSubmissionIsNeverRetried() throws {
    let (root, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let backend = Backend(); backend.failUp = true
    assertUnknown({ _ = try backend.delivery().press(.init(x: 1, y: 2), target: target) }, released: false)
    XCTAssertEqual(backend.events.map(\.type), [.mouseMoved, .leftMouseDown, .leftMouseUp])
    XCTAssertThrowsError(try backend.delivery().press(.init(x: 1, y: 2), target: target)) { error in
      guard case HelperError.commandFailed(_, let details) = error else { return XCTFail("Expected unknown release") }
      XCTAssertEqual(details["releaseUncertain"], "true")
    }
  }
  func testUnboundedOrNonfiniteRequestsNeverReachBackend() throws {
    let (root, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    for request in [MouseClickRequest(x: .nan, y: 1), .init(x: 1, y: .infinity), .init(x: 1, y: 1, clicks: Int.max),
      .init(x: 1, y: 1, holdMs: -1), .init(x: 1, y: 1, holdMs: 5000, clicks: 8, doubleClick: true)] {
      let backend = Backend()
      XCTAssertThrowsError(try backend.delivery().press(request, target: target)); XCTAssertTrue(backend.events.isEmpty)
    }
  }
  func testOwnedPressGrammarRejectsMissingIdentityDuplicateAndUnboundSurface() throws {
    let (root, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let args = ["--x", "1", "--y", "2", "--surface", "frontmost-app", "--bundle-id", target.bundleId,
      "--target-bundle-path", target.canonicalBundlePath, "--target-pid", "12", "--target-process-start", "1:0"]
    XCTAssertEqual(try MacOwnedPressArguments.from(args).target, target)
    for invalid in [Array(args.prefix(6)), args + ["--x", "4"], args + ["--double-click", "--double-click"], args + ["--unknown", "1"],
      ["--x=1"] + Array(args.dropFirst(2))] { XCTAssertThrowsError(try MacOwnedPressArguments.from(invalid)) }
    var wrongSurface = args; wrongSurface[5] = "desktop"
    XCTAssertThrowsError(try MacOwnedPressArguments.from(wrongSurface))
  }
  func testDispatcherCannotDowngradeOwnedPressOrSnapshotToLegacyMode() {
    XCTAssertThrowsError(try AgentDeviceMacOSHelper.run(arguments: ["press", "--x", "1", "--y", "2", "--surface", "frontmost-app"])) { error in
      guard case HelperError.invalidArgs(let message) = error else { return XCTFail("Expected ownership rejection") }
      XCTAssertEqual(message, "press requires its complete exact-process identity and application surface")
    }
    XCTAssertThrowsError(try AgentDeviceMacOSHelper.run(arguments: ["snapshot", "--surface", "frontmost-app"])) { error in
      guard case HelperError.invalidArgs(let message) = error else { return XCTFail("Expected ownership rejection") }
      XCTAssertEqual(message, "snapshot requires complete exact-process identity")
    }
  }
}
