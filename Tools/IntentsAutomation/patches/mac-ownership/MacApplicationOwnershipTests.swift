import Foundation
import XCTest
@testable import AgentDeviceMacOSHelper

final class MacApplicationOwnershipTests: XCTestCase {
  func testLaunchConfigurationPreventsSubstitutionAndActivationBeforeIdentityCheck() {
    let configuration = MacApplicationOwnership.launchConfiguration()
    XCTAssertFalse(configuration.allowsRunningApplicationSubstitution)
    XCTAssertTrue(configuration.createsNewApplicationInstance)
    XCTAssertFalse(configuration.activates)
    XCTAssertFalse(configuration.promptsUserIfNeeded)
    XCTAssertFalse(configuration.addsToRecentItems)
  }
  private func fixture() throws -> (URL, MacApplicationSelection, MacApplicationTarget) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
      .appendingPathComponent("mac-open-" + UUID().uuidString + ".app")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "example.Target", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
    try data.write(to: root.appendingPathComponent("Contents/Info.plist"))
    let selection = MacApplicationSelection(bundleId: "example.Target", canonicalBundlePath: root.path)
    return (root, selection, .init(bundleId: selection.bundleId, canonicalBundlePath: root.path, pid: 12, processStartIdentity: "1:0"))
  }

  func testIdentityResolvesOnlyTheSelectedCopyWithoutLaunchingOrActivating() throws {
    let (root, selection, selected) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let other = MacApplicationTarget(bundleId: selected.bundleId, canonicalBundlePath: "/Applications/Other.app", pid: 13, processStartIdentity: "2:0")
    var verifications = 0
    let ownership = MacApplicationOwnership(running: { _ in [other, selected] }, launch: { _ in XCTFail("Unexpected launch"); return other },
      verify: { XCTAssertEqual($0, selected); verifications += 1 }, activate: { _ in XCTFail("Unexpected activation") })
    XCTAssertEqual(try ownership.identity(selection), selected)
    XCTAssertEqual(verifications, 1)
  }

  func testAmbiguousExactInstancesAndMissingIdentityFailWithoutLaunch() throws {
    let (root, selection, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    for candidates in [[], [target, target]] {
      let ownership = MacApplicationOwnership(running: { _ in candidates }, launch: { _ in XCTFail("Unexpected launch"); return target },
        verify: { _ in XCTFail("Unexpected verification") }, activate: { _ in XCTFail("Unexpected activation") })
      XCTAssertThrowsError(try ownership.identity(selection))
      if !candidates.isEmpty { XCTAssertThrowsError(try ownership.open(selection)) }
    }
  }

  func testOpenChecksCapturedInstanceBeforeAndAfterActivation() throws {
    let (root, selection, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    var events: [String] = []
    let ownership = MacApplicationOwnership(running: { _ in [] }, launch: { actual in XCTAssertEqual(actual, selection); events.append("launch"); return target },
      verify: { actual in XCTAssertEqual(actual, target); events.append("verify") }, activate: { actual in XCTAssertEqual(actual, target); events.append("activate") })
    XCTAssertEqual(try ownership.open(selection), target)
    XCTAssertEqual(events, ["launch", "verify", "activate", "verify"])
  }

  func testExistingExactInstanceIsReusedWithoutAnyLaunch() throws {
    let (root, selection, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    var activations = 0
    let ownership = MacApplicationOwnership(running: { _ in [target] }, launch: { _ in XCTFail("Unexpected launch"); return target },
      verify: { _ in }, activate: { _ in activations += 1 })
    XCTAssertEqual(try ownership.open(selection), target)
    XCTAssertEqual(activations, 1)
  }

  func testWrongLaunchedCopyIsUncertainAndNeverActivatedOrRetried() throws {
    let (root, selection, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let (otherRoot, _, other) = try fixture(); defer { try? FileManager.default.removeItem(at: otherRoot) }
    var launches = 0
    let ownership = MacApplicationOwnership(running: { _ in [] }, launch: { _ in launches += 1; return other },
      verify: { _ in XCTFail("Wrong copy must not reach verification") }, activate: { _ in XCTFail("Wrong copy must not activate") })
    XCTAssertThrowsError(try ownership.open(selection)) { error in
      guard case HelperError.commandFailed(_, let details) = error else { return XCTFail("Expected unresolved acquisition") }
      XCTAssertEqual(details["acquisitionUncertain"], "true")
    }
    XCTAssertEqual(launches, 1); XCTAssertNotEqual(other, target)
  }

  func testPostActivationIdentityLossIsUncertainWithNoRetry() throws {
    let (root, selection, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    var verifications = 0, activations = 0
    let ownership = MacApplicationOwnership(running: { _ in [] }, launch: { _ in target }, verify: { _ in
      verifications += 1
      if verifications == 2 { throw HelperError.commandFailed("process changed") }
    }, activate: { _ in activations += 1 })
    XCTAssertThrowsError(try ownership.open(selection)) { error in
      guard case HelperError.commandFailed(_, let details) = error else { return XCTFail("Expected unresolved acquisition") }
      XCTAssertEqual(details["acquisitionUncertain"], "true")
    }
    XCTAssertEqual(activations, 1); XCTAssertEqual(verifications, 2)
  }

  func testLaunchAndActivationFailuresRemainUncertainWithoutRetry() throws {
    let (root, selection, target) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    for failLaunch in [true, false] {
      var launches = 0, activations = 0
      let ownership = MacApplicationOwnership(running: { _ in [] }, launch: { _ in
        launches += 1
        if failLaunch { throw HelperError.commandFailed("launch failed") }
        return target
      }, verify: { _ in }, activate: { _ in activations += 1; throw HelperError.commandFailed("activation failed") })
      XCTAssertThrowsError(try ownership.open(selection)) { error in
        guard case HelperError.commandFailed(_, let details) = error else { return XCTFail("Expected uncertain acquisition") }
        XCTAssertEqual(details["acquisitionUncertain"], "true")
      }
      XCTAssertEqual(launches, 1); XCTAssertEqual(activations, failLaunch ? 0 : 1)
    }
  }

  func testSelectionGrammarRejectsMissingDuplicateAliasAndExtraArguments() throws {
    let (root, selection, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let args = ["--bundle-id", selection.bundleId, "--bundle-path", selection.canonicalBundlePath]
    XCTAssertEqual(try MacApplicationSelection.from(arguments: args), selection)
    for invalid in [Array(args.dropLast()), args + ["--activate"], ["--bundle-id", selection.bundleId, "--bundle-id", selection.bundleId],
      ["--bundle-id=" + selection.bundleId, "--bundle-path", selection.canonicalBundlePath, "extra"]] {
      XCTAssertThrowsError(try MacApplicationSelection.from(arguments: invalid))
    }
    var invalid = args; invalid[3] += "/"
    XCTAssertThrowsError(try MacApplicationSelection.from(arguments: invalid))
  }
}
