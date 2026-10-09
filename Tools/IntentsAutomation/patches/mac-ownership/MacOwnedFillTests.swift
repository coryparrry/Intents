import ApplicationServices
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
  private final class Counter { var value = 0 }
  private struct FakeNode {
    var pid: pid_t = 123
    var role: String? = "AXGroup"
    var subrole: (status: AXError, value: String?) = (.noValue, nil)
    var enabled: Bool? = true
    var settable = true
  }
  private let field = FakeNode(role: "AXTextField", subrole: (.attributeUnsupported, nil))
  private let root = FakeNode(role: "AXApplication")
  private func ancestry(_ middle: [FakeNode] = [FakeNode()], field: FakeNode? = nil) -> [FakeNode] {
    [field ?? self.field] + middle + [root]
  }
  private func refusal(_ nodes: [FakeNode], frontmost: Bool = true, confirmations: Counter = Counter()) -> String? {
    let accessor = MacOrdinaryFieldAccessor<Int>(pid: { nodes[$0].pid }, role: { nodes[$0].role }, enabled: { nodes[$0].enabled },
      valueSettable: { nodes[$0].settable }, subrole: { nodes[$0].subrole }, parent: { $0 + 1 < nodes.count ? $0 + 1 : nil },
      confirmFrontmost: {
        confirmations.value += 1
        guard frontmost else { throw HelperError.commandFailed("selected app changed before fill") }
      })
    do { try verifyMacOrdinaryField(0, target: target, accessor: accessor); return nil } catch HelperError.commandFailed(let message, _) { return message } catch { return "\(error)" }
  }
  private func invalidArgs(_ body: () throws -> Any) -> String? {
    do { _ = try body(); return nil } catch HelperError.invalidArgs(let message) { return message } catch { return "\(error)" }
  }
  private func write(_ text: String, to descriptor: Int32) {
    let data = Data(text.utf8)
    XCTAssertEqual(data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }, data.count)
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
  func testOrdinaryFieldWithSameOwnerAncestryAndFrontmostRootIsAdmitted() {
    let confirmations = Counter()
    for status in [AXError.success, .attributeUnsupported, .noValue] {
      let ordinary = FakeNode(subrole: (status, status == .success ? "AXSearchField" : nil))
      var fieldNode = field; fieldNode.subrole = ordinary.subrole; fieldNode.role = "AXTextArea"
      XCTAssertNil(refusal(ancestry([ordinary], field: fieldNode), confirmations: confirmations))
    }
    XCTAssertEqual(confirmations.value, 3)
  }
  func testSecureFieldOrSecureAncestorIsRefusedBeforeFrontmostCheck() {
    let confirmations = Counter()
    var secureField = field; secureField.subrole = (.success, "AXSecureTextField")
    XCTAssertEqual(refusal(ancestry(field: secureField), confirmations: confirmations), "secure field is outside ordinary fill")
    XCTAssertEqual(refusal(ancestry([FakeNode(), FakeNode(subrole: (.success, "AXSecureTextField"))]), confirmations: confirmations),
      "secure field is outside ordinary fill")
    XCTAssertEqual(confirmations.value, 0)
  }
  func testUnexpectedSubroleErrorOnFieldOrAncestorIsRefused() {
    for status in [AXError.cannotComplete, .failure, .apiDisabled] {
      var failingField = field; failingField.subrole = (status, nil)
      XCTAssertEqual(refusal(ancestry(field: failingField)), "secure field is outside ordinary fill")
      XCTAssertEqual(refusal(ancestry([FakeNode(subrole: (status, nil))])), "secure field is outside ordinary fill")
    }
  }
  func testForeignOwnerOnFieldOrAncestorIsRefused() {
    var foreignField = field; foreignField.pid = 456
    XCTAssertEqual(refusal(ancestry(field: foreignField)), "selected field cannot accept ordinary replacement")
    XCTAssertEqual(refusal(ancestry([FakeNode(), FakeNode(pid: 456)])), "ordinary field owner changed")
    var foreignRoot = ancestry(); foreignRoot[foreignRoot.count - 1].pid = 456
    XCTAssertEqual(refusal(foreignRoot), "ordinary field owner changed")
  }
  func testDisabledNonSettableOrNonTextFieldIsRefused() {
    var disabled = field; disabled.enabled = false
    var unknownEnabled = field; unknownEnabled.enabled = nil
    var fixed = field; fixed.settable = false
    var button = field; button.role = "AXButton"
    var roleless = field; roleless.role = nil
    for candidate in [disabled, unknownEnabled, fixed, button, roleless] {
      XCTAssertEqual(refusal(ancestry(field: candidate)), "selected field cannot accept ordinary replacement")
    }
  }
  func testAncestryIsBoundedToThirtyTwoNodesAndMustReachTheApplication() {
    XCTAssertNil(refusal(ancestry(Array(repeating: FakeNode(), count: 30))))
    XCTAssertEqual(refusal(ancestry(Array(repeating: FakeNode(), count: 31))), "ordinary field ancestry exceeds bound")
    XCTAssertEqual(refusal([field, FakeNode()]), "ordinary field ancestry unavailable")
  }
  func testApplicationRootThatIsNotFrontmostIsRefused() {
    let confirmations = Counter()
    XCTAssertEqual(refusal(ancestry(), frontmost: false, confirmations: confirmations), "selected app changed before fill")
    XCTAssertEqual(confirmations.value, 1)
  }
  func testFillArgumentsRejectCallerDirectionAndMissingStartupNonceBeforeReadingInput() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
      .appendingPathComponent("intents-fill-\(UUID().uuidString)", isDirectory: true)
    let bundle = directory.appendingPathComponent("Fixture.app", isDirectory: true)
    try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.fixture", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
    try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    let arguments = ["--x", "20", "--y", "30", "--surface", "frontmost-app", "--bundle-id", "test.fixture",
      "--target-bundle-path", bundle.path, "--target-pid", "123", "--target-process-start", "123:0"]
    XCTAssertEqual(invalidArgs { try performMacOwnedFill(arguments: arguments + ["--direction", "up"]) }, "invalid ordinary fill arguments")
    XCTAssertEqual(invalidArgs { try performMacOwnedFill(arguments: ["--direction", "down"] + arguments) }, "invalid ordinary fill arguments")
    let saved = getenv("INTENTS_MAC_HELPER_OWNERSHIP_NONCE").map { String(cString: $0) }
    unsetenv("INTENTS_MAC_HELPER_OWNERSHIP_NONCE")
    defer { if let saved { setenv("INTENTS_MAC_HELPER_OWNERSHIP_NONCE", saved, 1) } }
    XCTAssertEqual(invalidArgs { try performMacOwnedFill(arguments: arguments) }, "private fill startup missing")
  }
  func testFrameReaderRejectsInvalidBoundsBeforeReading() throws {
    var pair: [Int32] = [-1, -1]; XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
    defer { close(pair[0]); close(pair[1]) }
    write("x\n", to: pair[1])
    for maximum in [0, -1, MacPrivateInput.maximumFrameBytes + 1] {
      XCTAssertEqual(invalidArgs { try MacPrivateInput.readLine(descriptor: pair[0], maximum: maximum, deadline: .now.advanced(by: .seconds(1))) },
        "private input bound invalid")
    }
    XCTAssertEqual(try MacPrivateInput.readLine(descriptor: pair[0], maximum: MacPrivateInput.maximumFrameBytes, deadline: .now.advanced(by: .seconds(1))), Data("x\n".utf8))
  }
  func testHangupAfterPartialFrameFailsIncompleteNotDeadline() throws {
    var pair: [Int32] = [-1, -1]; XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
    defer { close(pair[0]); close(pair[1]) }
    write("{\"partial\"", to: pair[1])
    XCTAssertEqual(shutdown(pair[1], SHUT_WR), 0)
    XCTAssertEqual(invalidArgs { try MacPrivateInput.readLine(descriptor: pair[0], maximum: 4096, deadline: .now.advanced(by: .seconds(5))) },
      "private input incomplete")
  }
  func testNonceMustBeLowercaseCanonicalUUID() throws {
    for candidate in [nonce.uppercased(), "12345678123412341234123456789abc", "not-a-uuid"] {
      let value = MacOrdinaryFillFrame(schemaVersion: 1, kind: "ordinaryFill", nonce: candidate, applicationTarget: target, x: 20, y: 30, value: "public")
      XCTAssertEqual(invalidArgs { try MacOrdinaryFillFrame.decode(encode(value), nonce: candidate, target: target, x: 20, y: 30) }, "invalid private fill frame")
    }
  }
  func testCoordinatesAreBoundedToOneMillion() throws {
    func point(_ x: Double, _ y: Double) throws -> MacOrdinaryFillFrame {
      let value = MacOrdinaryFillFrame(schemaVersion: 1, kind: "ordinaryFill", nonce: nonce, applicationTarget: target, x: x, y: y, value: "public")
      return try MacOrdinaryFillFrame.decode(encode(value), nonce: nonce, target: target, x: x, y: y)
    }
    let accepted: [(Double, Double)] = [(1_000_000, 1_000_000), (-1_000_000, -1_000_000), (1_000_000, -1_000_000)]
    let rejected: [(Double, Double)] = [(1_000_001, 0), (0, 1_000_001), (-1_000_001, 0), (0, -1_000_001)]
    for (x, y) in accepted {
      XCTAssertNoThrow(try point(x, y))
    }
    for (x, y) in rejected {
      XCTAssertEqual(invalidArgs { try point(x, y) }, "invalid private fill frame")
    }
  }
}
