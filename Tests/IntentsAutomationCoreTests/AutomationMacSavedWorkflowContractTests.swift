#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationMacSavedWorkflowContractTests: XCTestCase, @unchecked Sendable {
    struct Fixture {
        let root: URL, selected: AutomationInstalledMacUIApplication, frozen: AutomationFrozenCase, original: AutomationAttemptReport
        let evidence: AutomationPrivateMacDaemonUnit.Evidence
        var dependencies: AutomationMacSavedWorkflowContract.Dependencies {
            .init(currentTarget: { selected.target }, runtime: { _ in evidence }, locale: { "en_GB" })
        }
    }
    func product(_ root: URL, name: String, bundleID: String = "example.SavedMac", version: String = "1") throws -> URL {
        let bundle = root.appendingPathComponent(name + ".app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL",
            "CFBundleSupportedPlatforms": ["MacOSX"], "CFBundleVersion": version], format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try AutomationPhysicalExecutableTests.binary(platform: 1).write(to: bundle.appendingPathComponent("Contents/MacOS/Fixture")); return bundle
    }
    func fixture(environment: String? = nil, locale: String = "en_GB", receipt: String = AutomationPrivateMacDaemonUnit.pinnedProgramReceiptSHA256,
                 mutating: Bool = false, unsupported: Bool = false) throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/saved-mac-contract-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let selected = try AutomationInstalledMacUIApplication(bundleURL: product(root, name: "Before"), target: .init(id: "host-macos-local", kind: .nativeMac, loginSession: "synthetic-login"))
        var subject = AutomationSegment(id: "subject", kind: .ui, phase: .subject, operation: "Open", effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
        subject.uiProgram = .init(operations: [.init(id: "tap", kind: .tap, locator: .init(.label, "Ready"))])
        if mutating { subject.effects.insert(.fixtureWrite) }
        if unsupported { subject.uiProgram = .init(operations: [.init(id: "fill", kind: .fillBinding, locator: .init(.label, "Name"), binding: "name")], bindings: ["name": "value"]) }
        var observer = subject; observer.id = "observer"; observer.phase = .observe; observer.effects = [.observe, .navigate]
        observer.uiProgram = .init(operations: [.init(id: "status", kind: .observeProperty, locator: .init(.testId, "status"), property: "text")])
        var plan = AutomationCase(id: "saved-mac", app: selected.app, target: selected.target, environmentID: environment ?? "selected-mac-session:synthetic-login",
            execution: subject, observations: [observer], requirements: [.init(observationID: "observer", expected: .text("Expected"), proof: .visibleState, justification: "Independent UI state")])
        plan.provenance["ui.locale"] = locale; plan.provenance["ui.privateMacReceiptSHA256"] = receipt
        let frozen = try AutomationFrozenCase(plan: plan)
        let observation = AutomationObservation(id: "observer", app: plan.app, target: plan.target, environmentID: plan.environmentID,
            attemptID: "original", stepID: "observer", route: .ui, proof: .visibleState, value: .text("Different"))
        let receipts = [subject, observer].enumerated().map { index, segment in
            AutomationSegmentReceipt(scope: .init(runID: "original-run", attemptID: "original", segmentID: segment.id, leaseGeneration: index + 1),
                app: plan.app, target: plan.target, segmentID: segment.id, route: .ui, dispatched: true, completed: true,
                observations: segment.phase == .observe ? [observation] : [], environmentID: plan.environmentID)
        }
        let original = AutomationAttemptReport(attemptID: "original", result: AutomationAssessment.assess(plan: plan, attemptID: "original", subjectDispatched: true,
            subjectCompleted: true, observations: [observation], receipts: receipts, runID: "original-run"), receipts: receipts, resourcesReleased: true)
        let evidence = AutomationPrivateMacDaemonUnit.Evidence(receiptSHA256: AutomationPrivateMacDaemonUnit.pinnedProgramReceiptSHA256,
            checkpointSHA256: String(repeating: "b", count: 64), fileCount: 5473, customerRuntimeEnabled: false, hardwareQualified: false, developerIDSigned: false)
        return .init(root: root, selected: selected, frozen: frozen, original: original, evidence: evidence)
    }
    func review(_ f: Fixture, original: AutomationAttemptReport? = nil, dependencies: AutomationMacSavedWorkflowContract.Dependencies? = nil) throws -> AutomationMacSavedWorkflowContract.Reproduction {
        try AutomationMacSavedWorkflowContract.reproduction(frozen: f.frozen, original: original ?? f.original, selected: f.selected,
            runtimeRoot: f.root, runID: "reproduce", dependencies: dependencies ?? f.dependencies)
    }
    func testExactReadOnlyMacFailureGetsSessionRuntimeAndCaseBoundReview() throws {
        let f = try fixture(), reviewed = try review(f)
        XCTAssertEqual(reviewed.frozen, f.frozen); XCTAssertEqual(reviewed.originalAttemptID, "original")
        XCTAssertEqual(reviewed.approval.target, f.selected.target); XCTAssertEqual(reviewed.approval.approvedCaseDigest, f.frozen.digest)
        XCTAssertEqual(reviewed.approval.environmentID, "selected-mac-session:synthetic-login"); XCTAssertEqual(reviewed.approval.effects, [.observe, .navigate])
        XCTAssertEqual(reviewed.runtimeEvidence, f.evidence); XCTAssertFalse(reviewed.runtimeEvidence.customerRuntimeEnabled); XCTAssertFalse(reviewed.runtimeEvidence.hardwareQualified)
    }
    func testChangedEnvironmentLocaleReceiptAndMutatingOrUnsupportedProgramsAreRejected() throws {
        let cases = [try fixture(environment: "selected-simulator:foreign"), try fixture(locale: "foreign"), try fixture(receipt: String(repeating: "b", count: 64)),
                     try fixture(mutating: true), try fixture(unsupported: true)]
        for f in cases { XCTAssertThrowsError(try review(f)) }
    }
    func testUnreleasedUnassessedAndChangedProductCannotBeReviewed() throws {
        let f = try fixture(); var unreleased = f.original; unreleased.resourcesReleased = false
        XCTAssertThrowsError(try review(f, original: unreleased))
        var unassessed = f.original; unassessed.result.assessed = false; unassessed.result.evidenceComplete = false
        XCTAssertThrowsError(try review(f, original: unassessed))
        try Data("changed".utf8).write(to: f.selected.bundleURL.appendingPathComponent("Contents/MacOS/Fixture"))
        XCTAssertThrowsError(try review(f))
    }
    final class TargetSequence: @unchecked Sendable {
        let lock = NSLock(), expected: TargetIdentity
        var calls = 0
        init(_ expected: TargetIdentity) { self.expected = expected }
        func current() -> TargetIdentity {
            lock.withLock { calls += 1; var result = expected; if calls > 1 { result.loginSession = "foreign" }; return result }
        }
    }
    func testGUIChangeDuringIndependentRuntimeReadIsRejected() throws {
        let f = try fixture(), sequence = TargetSequence(f.selected.target); var dependencies = f.dependencies
        dependencies.currentTarget = { sequence.current() }
        XCTAssertThrowsError(try review(f, dependencies: dependencies))
    }
    func testSeparatelyRetainedMacFixPreservesActualPathAndSharedOracle() throws {
        let f = try fixture(), afterURL = try product(f.root, name: "After", version: "2")
        let after = try AutomationInstalledMacUIApplication.comparisonCandidate(bundleURL: afterURL, target: f.selected.target, baseline: f.selected.app)
        XCTAssertEqual(after.app.logicalID, f.selected.app.logicalID); XCTAssertEqual(after.app.canonicalBundlePath, afterURL.path)
        XCTAssertNotEqual(after.bundleURL, f.selected.bundleURL); XCTAssertNotEqual(after.app.productDigest, f.selected.app.productDigest)
        let reviewed = try AutomationMacSavedWorkflowContract.comparison(frozen: f.frozen, original: f.original, before: f.selected, after: after,
            runtimeRoot: f.root, runID: "compare", dependencies: f.dependencies)
        XCTAssertEqual(reviewed.candidate.contractDigest, reviewed.baseline.contractDigest); XCTAssertEqual(reviewed.candidate.oracleDigest, reviewed.baseline.oracleDigest)
        XCTAssertEqual(reviewed.beforeApproval.runID, "compare.before"); XCTAssertEqual(reviewed.afterApproval.runID, "compare.after")
        XCTAssertEqual(reviewed.afterApproval.approvedCaseDigest, reviewed.candidate.digest)
    }
    func testUnchangedForeignBundleAndForeignSessionFixesAreRejected() throws {
        let f = try fixture()
        XCTAssertThrowsError(try AutomationInstalledMacUIApplication.comparisonCandidate(bundleURL: f.selected.bundleURL, target: f.selected.target, baseline: f.selected.app))
        let foreign = try product(f.root, name: "Foreign", bundleID: "foreign.App", version: "2")
        XCTAssertThrowsError(try AutomationInstalledMacUIApplication.comparisonCandidate(bundleURL: foreign, target: f.selected.target, baseline: f.selected.app))
        let afterURL = try product(f.root, name: "After", version: "2")
        var target = f.selected.target; target.loginSession = "foreign"
        let after = try AutomationInstalledMacUIApplication.comparisonCandidate(bundleURL: afterURL, target: target, baseline: f.selected.app)
        XCTAssertThrowsError(try AutomationMacSavedWorkflowContract.comparison(frozen: f.frozen, original: f.original, before: f.selected, after: after,
            runtimeRoot: f.root, runID: "compare", dependencies: f.dependencies))
    }
}
#endif
