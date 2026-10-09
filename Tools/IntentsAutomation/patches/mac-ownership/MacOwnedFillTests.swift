import Darwin
import Foundation
import XCTest
@testable import AgentDeviceMacOSHelper

final class MacOwnedFillTests: XCTestCase {
  private let nonce = "12345678-1234-1234-1234-123456789abc"
  private var target: MacApplicationTarget { .init(bundleId: "test.fixture", canonicalBundlePath: "/synthetic/Fixture.app", pid: 123, processStartIdentity: "123:0") }
  private func frame(_ value: String = "public literal") -> MacOrdinaryFillFrame {
    .init(schemaVersion: 1, kind: "ordinaryFill", nonce: nonce, applicationTarget: target, x: 20, y: 30, value: value)
  }
  private func encode(_ frame: MacOrdinaryFillFrame) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(frame); data.append(10); return data
  }
  private func decode(_ bytes: Data, x: Double = 20, nonce: String? = nil) throws -> MacOrdinaryFillFrame {
    try .decode(bytes, nonce: nonce ?? self.nonce, target: target, x: x, y: 30)
  }
  func testEditableProbeNeverQueriesSecureInheritedDisabledOrNonTextNodes() {
    var probes = 0
    let query = { probes += 1; return true }
    for (role, subrole, enabled, inherited) in [("AXTextField", "AXSecureTextField", true, false),
      ("AXTextField", "", true, true), ("AXTextField", "", false, false), ("AXButton", "", true, false)] {
      XCTAssertFalse(MacOrdinaryFillCapability.probe(role: role, subrole: subrole, enabled: enabled, inherited: inherited, settable: query))
    }
    XCTAssertEqual(probes, 0)
    XCTAssertTrue(MacOrdinaryFillCapability.probe(role: "AXTextField", subrole: nil, enabled: true, inherited: false, settable: query))
    XCTAssertEqual(probes, 1)
    XCTAssertFalse(MacOrdinaryFillCapability.probe(role: "AXTextArea", subrole: nil, enabled: true, inherited: false, settable: { false }))
  }
  func testCapturedSecureSubroleCannotBeDowngradedByFreshOrdinaryMetadata() {
    for freshSubrole in [Optional<String>.none, "AXSearchField"] {
      var rereads = 0
      let result = MacOrdinaryFillCapability.probe(role: "AXTextField", subrole: "AXSecureTextField", enabled: true, inherited: false) {
        rereads += 1
        return MacOrdinaryFillCapability.probe(role: "AXTextField", subrole: freshSubrole, enabled: true, inherited: false) { true }
      }
      XCTAssertFalse(result); XCTAssertEqual(rereads, 0)
    }
  }
  func testCanonicalFrameBindsNonceExactTargetAndPointWithoutNormalizingText() throws {
    let original = frame("e\u{301}\n"); let decoded = try decode(encode(original))
    XCTAssertTrue(decoded.value.utf16.elementsEqual(original.value.utf16))
    XCTAssertThrowsError(try decode(encode(original), x: 21))
    XCTAssertThrowsError(try decode(encode(original), nonce: "aaaaaaaa-1234-1234-1234-123456789abc"))
    XCTAssertNoThrow(try decode(encode(frame(""))))
  }
  func testCanonicallyEquivalentDifferentTargetPathIsRejected() throws {
    let supplied = MacApplicationTarget(bundleId: target.bundleId, canonicalBundlePath: "/synthetic/e\u{301}.app", pid: target.pid, processStartIdentity: target.processStartIdentity)
    let expected = MacApplicationTarget(bundleId: target.bundleId, canonicalBundlePath: "/synthetic/é.app", pid: target.pid, processStartIdentity: target.processStartIdentity)
    let value = MacOrdinaryFillFrame(schemaVersion: 1, kind: "ordinaryFill", nonce: nonce, applicationTarget: supplied, x: 20, y: 30, value: "public")
    XCTAssertThrowsError(try MacOrdinaryFillFrame.decode(encode(value), nonce: nonce, target: expected, x: 20, y: 30))
  }
  func testFrameRejectsExtrasDuplicatesIncompleteUnicodeOversizeAndNulWithoutEchoing() throws {
    let valid = try encode(frame("private-sentinel"))
    for bytes in [Data(valid.dropLast()), Data("{\"schemaVersion\":1,".utf8) + valid.dropFirst(),
                  Data(valid.dropLast(2)) + Data(",\"extra\":true}\n".utf8),
                  try encode(frame(String(repeating: "a", count: 16385))),
                  try encode(frame("x\0private-sentinel")), Data([0xff, 10])] {
      do { _ = try decode(bytes); XCTFail("invalid frame admitted") } catch {
        XCTAssertFalse(String(describing: error).contains("private-sentinel"))
      }
    }
  }
  func testTwoCoalescedFramesAreReadSeparatelyAndBounded() throws {
    var pair: [Int32] = [-1, -1]; XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
    defer { close(pair[0]); close(pair[1]) }
    let both = Data("ack\nfill\n".utf8)
    XCTAssertEqual(both.withUnsafeBytes { Darwin.write(pair[1], $0.baseAddress, $0.count) }, both.count)
    XCTAssertEqual(try MacPrivateInput.readLine(descriptor: pair[0], maximum: 4096, deadline: .now.advanced(by: .seconds(1))), Data("ack\n".utf8))
    XCTAssertEqual(try MacPrivateInput.readLine(descriptor: pair[0], maximum: 4096, deadline: .now.advanced(by: .seconds(1))), Data("fill\n".utf8))
    let oversized = Data("xxxx\n".utf8)
    _ = oversized.withUnsafeBytes { Darwin.write(pair[1], $0.baseAddress, $0.count) }
    XCTAssertThrowsError(try MacPrivateInput.readLine(descriptor: pair[0], maximum: 3, deadline: .now.advanced(by: .seconds(1))))
  }
  func testMissingOrUnterminatedFrameFailsAtDeadlineOrEOF() throws {
    var pair: [Int32] = [-1, -1]; XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
    defer { close(pair[0]) }
    XCTAssertThrowsError(try MacPrivateInput.readLine(descriptor: pair[0], maximum: 4096, deadline: .now.advanced(by: .milliseconds(20))))
    let partial = Data("no newline".utf8); _ = partial.withUnsafeBytes { Darwin.write(pair[1], $0.baseAddress, $0.count) }
    close(pair[1])
    XCTAssertThrowsError(try MacPrivateInput.readLine(descriptor: pair[0], maximum: 4096, deadline: .now.advanced(by: .seconds(1))))
  }
  func testReplacementChecksFreshElementBeforeSetterAndReadbackWithoutValueReceipt() throws {
    var calls = [String](), stored = "old"
    let delivery = MacOwnedFillDelivery<Int>(resolve: { calls.append("resolve"); return 7 }, verify: { element in
      XCTAssertEqual(element, 7); calls.append("verify")
    }, replace: { _, value in calls.append("replace"); stored = value }, readback: { _ in calls.append("readback"); return stored })
    let receipt = try delivery.fill(frame("private-sentinel"))
    XCTAssertEqual(calls, ["resolve", "verify", "replace", "verify", "readback"])
    let bytes = try JSONEncoder().encode(receipt)
    XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("private-sentinel"))
    XCTAssertEqual(receipt.disposition, "replacementVerified")
  }
  func testInvalidFieldFailsBeforeSetterAndUncertainSetterIsNeverRetried() throws {
    var writes = 0, reads = 0
    let invalid = MacOwnedFillDelivery<Int>(resolve: { 7 }, verify: { _ in throw HelperError.commandFailed("secure or stale") },
      replace: { _, _ in writes += 1 }, readback: { _ in reads += 1; return "" })
    XCTAssertThrowsError(try invalid.fill(frame())); XCTAssertEqual(writes, 0); XCTAssertEqual(reads, 0)
    let uncertain = MacOwnedFillDelivery<Int>(resolve: { 7 }, verify: { _ in }, replace: { _, _ in
      writes += 1; throw HelperError.commandFailed("private-sentinel")
    }, readback: { _ in reads += 1; return "" })
    do { _ = try uncertain.fill(frame()); XCTFail("uncertain setter succeeded") } catch {
      XCTAssertFalse(String(describing: error).contains("private-sentinel"))
    }
    XCTAssertEqual(writes, 1); XCTAssertEqual(reads, 0)
  }
  func testCanonicallyEquivalentDifferentReadbackFailsWithoutEcho() throws {
    var writes = 0
    let delivery = MacOwnedFillDelivery<Int>(resolve: { 7 }, verify: { _ in }, replace: { _, _ in writes += 1 }, readback: { _ in "é" })
    XCTAssertThrowsError(try delivery.fill(frame("e\u{301}")))
    XCTAssertEqual(writes, 1)
  }
}
