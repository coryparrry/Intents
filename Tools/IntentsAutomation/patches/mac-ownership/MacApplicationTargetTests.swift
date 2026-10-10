import Darwin
import Foundation
import XCTest
@testable import AgentDeviceMacOSHelper

final class MacApplicationTargetTests: XCTestCase {
  func testOwnedTargetArgumentsCannotEnterAnyLegacyMutation() throws {
    for command in ["press", "alert", "permission", "app", "screenshot", "read", "audio-probe"] {
      for flags in [["--target-pid", "123"], ["--target-pid=123"]] {
        XCTAssertThrowsError(try AgentDeviceMacOSHelper.run(arguments: [command] + flags)) { error in
          guard case HelperError.invalidArgs(let message) = error else {
            return XCTFail("Expected the dispatcher rejection, got \(error)")
          }
          XCTAssertEqual(message, "exact-process Mac input is unavailable; no legacy fallback")
        }
      }
    }
  }
  private func fixture() throws -> (URL, MacApplicationTarget) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
      .appendingPathComponent("mac-target-" + UUID().uuidString + ".app")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "example.Target", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
    try data.write(to: root.appendingPathComponent("Contents/Info.plist"))
    return (root, .init(bundleId: "example.Target", canonicalBundlePath: root.path, pid: getpid(), processStartIdentity: "1:0"))
  }
  func testKernelStartTokenUsesCurrentProcessAndRejectsInvalidPID() throws {
    let token = try XCTUnwrap(MacApplicationTarget.kernelStartIdentity(pid: getpid()))
    XCTAssertEqual(token, MacApplicationTarget.kernelStartIdentity(pid: getpid()))
    XCTAssertNil(MacApplicationTarget.kernelStartIdentity(pid: 0))
    XCTAssertNil(MacApplicationTarget.kernelStartIdentity(pid: -1))
    XCTAssertTrue(token.contains(":"))
  }
  func testArgumentIdentityIsCompleteCanonicalAndDoesNotResolveByBundleAlone() throws {
    let (root, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let args = ["--bundle-id", target.bundleId, "--target-bundle-path", target.canonicalBundlePath,
      "--target-pid", String(target.pid), "--target-process-start", target.processStartIdentity]
    XCTAssertEqual(try MacApplicationTarget.from(arguments: args), target)
    XCTAssertNil(try MacApplicationTarget.from(arguments: ["--bundle-id", target.bundleId]))
    XCTAssertThrowsError(try MacApplicationTarget.from(arguments: Array(args.dropLast(2))))
    XCTAssertThrowsError(try MacApplicationTarget.from(arguments: args + ["--target-pid", String(target.pid)]))
    XCTAssertTrue(MacApplicationTarget.hasTargetArguments(["--target-pid=123"]))
    XCTAssertThrowsError(try MacApplicationTarget.from(arguments: ["--target-pid=123"]))
    var leadingZero = args; leadingZero[5] = "0" + String(target.pid)
    XCTAssertThrowsError(try MacApplicationTarget.from(arguments: leadingZero))
  }
  func testPathBundleAndStartIdentityDriftAreRejected() throws {
    let (root, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertNoThrow(try target.validate())
    let candidates = [
      MacApplicationTarget(bundleId: "example.Other", canonicalBundlePath: root.path, pid: target.pid, processStartIdentity: "1:0"),
      MacApplicationTarget(bundleId: target.bundleId, canonicalBundlePath: root.path + "/", pid: target.pid, processStartIdentity: "1:0"),
      MacApplicationTarget(bundleId: target.bundleId, canonicalBundlePath: root.path, pid: 0, processStartIdentity: "1:0"),
      MacApplicationTarget(bundleId: target.bundleId, canonicalBundlePath: root.path, pid: target.pid, processStartIdentity: "01:0"),
      MacApplicationTarget(bundleId: target.bundleId, canonicalBundlePath: root.path, pid: target.pid, processStartIdentity: "1:0\n"),
      MacApplicationTarget(bundleId: target.bundleId, canonicalBundlePath: root.path, pid: target.pid, processStartIdentity: "18446744073709551616:0")]
    for candidate in candidates { XCTAssertThrowsError(try candidate.validate()) }
    XCTAssertThrowsError(try target.application()) // Incorrect kernel token never falls back to an app with the same bundle ID.
  }
  func testAliasAndPartialTargetCannotBeAccepted() throws {
    let (root, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let alias = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".app")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
    defer { try? FileManager.default.removeItem(at: alias) }
    XCTAssertThrowsError(try MacApplicationTarget(bundleId: target.bundleId, canonicalBundlePath: alias.path,
      pid: target.pid, processStartIdentity: "1:0").validate())
    XCTAssertThrowsError(try MacApplicationTarget.from(arguments: ["--target-process-start", "1:0"]))
  }
}
