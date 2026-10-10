import AgentDeviceMacOSInput
import CoreGraphics
import Foundation
import XCTest
@testable import AgentDeviceMacOSHelper

// CI-only overlay suite: staged next to the reviewed MacOwnedMouseDeliveryTests, whose pinned bytes stay unchanged.
final class MacOwnedMouseDeliveryCleanupTests: XCTestCase {
  private func fixture() throws -> (URL, MacApplicationTarget) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
      .appendingPathComponent("mac-input-cleanup-" + UUID().uuidString + ".app")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "example.Target", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
    try data.write(to: root.appendingPathComponent("Contents/Info.plist"))
    return (root, .init(bundleId: "example.Target", canonicalBundlePath: root.path, pid: 12, processStartIdentity: "1:0"))
  }

  private final class Recorder {
    var events: [MacOwnedMouseEvent] = []
    var targets: [MacApplicationTarget] = []
    var waits: [Int] = []
    var prepared = 0, targetChecks = 0, releaseChecks = 0
    var isCancelled = false
    var failPrepareAt: Int?
    var onPrepare: (() -> Void)?
    var onSubmit: ((MacOwnedMouseEvent) throws -> Void)?
    var onWait: (() -> Void)?
    var targetLost: () -> Bool = { false }
    var releaseTargetLost: (Int) -> Bool = { _ in false }
    var types: [CGEventType] { events.map(\.type) }

    func delivery() -> MacOwnedMouseDelivery<MacOwnedMouseEvent> {
      .init(prepare: { event in
        self.prepared += 1
        if self.prepared == self.failPrepareAt { throw HelperError.commandFailed("creation failed") }
        self.onPrepare?()
        return event
      }, submit: { event, target in
        self.events.append(event); self.targets.append(target)
        try self.onSubmit?(event)
      }, verifyTarget: { _ in
        self.targetChecks += 1
        if self.targetLost() { throw HelperError.commandFailed("target changed") }
      }, verifyReleaseTarget: { _ in
        self.releaseChecks += 1
        if self.releaseTargetLost(self.releaseChecks) { throw HelperError.commandFailed("PID reused") }
      }, cancelled: { self.isCancelled }, wait: { milliseconds in
        self.waits.append(milliseconds); self.onWait?()
      })
    }
  }

  private func failure(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) -> (message: String, details: [String: String])? {
    do {
      try body()
      XCTFail("Expected the press to fail", file: file, line: line)
    } catch HelperError.commandFailed(let message, let details) {
      return (message, details)
    } catch {
      XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
    return nil
  }

  private func assertUnknown(_ details: [String: String]?, released: Bool, uncertain: Bool, reason: String,
                             file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(details?["deliveryUnknown"], "true", file: file, line: line)
    XCTAssertEqual(details?["mayHaveCommitted"], "true", file: file, line: line)
    XCTAssertEqual(details?["releaseSubmitted"], String(released), file: file, line: line)
    XCTAssertEqual(details?["releaseUncertain"], String(uncertain), file: file, line: line)
    XCTAssertTrue(details?["reason"]?.contains(reason) == true, "reason: \(details?["reason"] ?? "nil")", file: file, line: line)
  }

  func testCancellationDuringInterClickDelaySendsNoFurtherDown() throws {
    let (root, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let requests = [MouseClickRequest(x: 1, y: 2, holdMs: 40, clicks: 3, intervalMs: 50),
                    MouseClickRequest(x: 1, y: 2, holdMs: 40, clicks: 1, doubleClick: true)]
    for request in requests {
      let recorder = Recorder()
      recorder.onWait = { if recorder.events.last?.type == .leftMouseUp { recorder.isCancelled = true } }
      let result = failure { _ = try recorder.delivery().press(request, target: target) }
      assertUnknown(result?.details, released: true, uncertain: false, reason: "cancelled")
      XCTAssertEqual(recorder.types, [.mouseMoved, .leftMouseDown, .leftMouseUp])
      // Four 10 ms hold steps, then exactly one gap step before cancellation is observed.
      XCTAssertEqual(recorder.waits, [10, 10, 10, 10, 10])
      XCTAssertEqual(recorder.releaseChecks, 1)
      XCTAssertTrue(recorder.targets.allSatisfy { $0 == target })
    }
  }

  func testReleaseTargetLossOnNormalReleaseIsNotSubmittedAndNotUncertain() throws {
    let (root, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let recorder = Recorder(); recorder.releaseTargetLost = { _ in true }
    let result = failure { _ = try recorder.delivery().press(.init(x: 1, y: 2), target: target) }
    assertUnknown(result?.details, released: false, uncertain: false, reason: "PID reused")
    XCTAssertEqual(recorder.types, [.mouseMoved, .leftMouseDown])
    // The normal release check and the cleanup check both refuse; no up reaches the PID.
    XCTAssertEqual(recorder.releaseChecks, 2)
  }

  func testCleanupReleaseFollowsTransientReleaseTargetRefusal() throws {
    let (root, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let recorder = Recorder(); recorder.releaseTargetLost = { $0 == 1 }
    let result = failure { _ = try recorder.delivery().press(.init(x: 1, y: 2, doubleClick: true), target: target) }
    assertUnknown(result?.details, released: true, uncertain: false, reason: "PID reused")
    XCTAssertEqual(recorder.types, [.mouseMoved, .leftMouseDown, .leftMouseUp])
    XCTAssertEqual(recorder.events.last, MacOwnedMouseEvent(type: .leftMouseUp, point: CGPoint(x: 1, y: 2), clickState: 1))
    XCTAssertEqual(recorder.releaseChecks, 2)
  }

  func testFailedCleanupReleaseSubmissionIsReportedUncertain() throws {
    let (root, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let recorder = Recorder()
    recorder.onSubmit = { event in
      if event.type == .leftMouseDown { throw HelperError.commandFailed("unknown down result") }
      if event.type == .leftMouseUp { throw HelperError.commandFailed("unknown up result") }
    }
    let result = failure { _ = try recorder.delivery().press(.init(x: 1, y: 2, clicks: 2), target: target) }
    assertUnknown(result?.details, released: false, uncertain: true, reason: "unknown down result")
    XCTAssertEqual(recorder.types, [.mouseMoved, .leftMouseDown, .leftMouseUp])
    XCTAssertEqual(recorder.releaseChecks, 1)
  }

  func testPrepareFailurePartwayThroughScheduleSendsNothing() throws {
    let (root, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    // One move plus a down/up pair for each of three presses.
    for failAt in 1...7 {
      let recorder = Recorder(); recorder.failPrepareAt = failAt
      let result = failure { _ = try recorder.delivery().press(.init(x: 1, y: 2, clicks: 3), target: target) }
      XCTAssertEqual(result?.message, "creation failed", "failAt \(failAt)")
      XCTAssertEqual(result?.details, [:], "failAt \(failAt)")
      XCTAssertTrue(recorder.events.isEmpty, "failAt \(failAt)")
      XCTAssertEqual(recorder.prepared, failAt)
      XCTAssertEqual(recorder.targetChecks, 1)
      XCTAssertEqual(recorder.releaseChecks, 0)
      XCTAssertTrue(recorder.waits.isEmpty)
    }
  }

  func testCancellationAfterPreparationButBeforeSubmissionIsNotReportedUnknown() throws {
    let (root, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let recorder = Recorder()
    recorder.onPrepare = { if recorder.prepared == 3 { recorder.isCancelled = true } }
    let result = failure { _ = try recorder.delivery().press(.init(x: 1, y: 2), target: target) }
    XCTAssertEqual(result?.message, "exact-process press cancelled before submission")
    XCTAssertEqual(result?.details, [:])
    XCTAssertTrue(recorder.events.isEmpty)
  }

  func testFrontmostLossAfterReleaseStopsBeforeNextDown() throws {
    let (root, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let recorder = Recorder(); recorder.targetLost = { recorder.events.last?.type == .leftMouseUp }
    let result = failure { _ = try recorder.delivery().press(.init(x: 1, y: 2, clicks: 3), target: target) }
    assertUnknown(result?.details, released: true, uncertain: false, reason: "target changed")
    XCTAssertEqual(recorder.types, [.mouseMoved, .leftMouseDown, .leftMouseUp])
    XCTAssertEqual(recorder.releaseChecks, 1)
  }

  func testCancellationAfterFinalReleaseIsStillUnknown() throws {
    let (root, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let recorder = Recorder()
    recorder.onSubmit = { event in if event.type == .leftMouseUp { recorder.isCancelled = true } }
    let result = failure { _ = try recorder.delivery().press(.init(x: 1, y: 2), target: target) }
    assertUnknown(result?.details, released: true, uncertain: false, reason: "cancelled")
    XCTAssertEqual(recorder.types, [.mouseMoved, .leftMouseDown, .leftMouseUp])
  }

  func testReceiptReportsEffectiveHoldAndEveryCheckRuns() throws {
    let (root, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    for (requested, effective) in [(0, 60), (10, 40), (75, 75)] {
      let recorder = Recorder()
      let receipt = try recorder.delivery().press(.init(x: 3, y: 4, holdMs: requested, clicks: 2, intervalMs: 30), target: target)
      XCTAssertEqual(receipt.holdMs, effective)
      XCTAssertEqual(receipt.clicks, 2); XCTAssertFalse(receipt.doubleClick)
      XCTAssertTrue(receipt.releaseSubmitted); XCTAssertEqual(receipt.disposition, "submittedUnconfirmed")
      XCTAssertEqual(receipt.applicationTarget, target)
      XCTAssertEqual(recorder.waits.reduce(0, +), effective * 2 + 30)
      XCTAssertTrue(recorder.waits.allSatisfy { (1...10).contains($0) })
      // Initial check, pre-submission check, then before each down and after each up.
      XCTAssertEqual(recorder.targetChecks, 6)
      XCTAssertEqual(recorder.releaseChecks, 2)
      XCTAssertEqual(recorder.types, [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
    }
  }
}
