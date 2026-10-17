#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationApplicationProbe
@testable import IntentsAutomationCore

final class AutomationCLIComparisonTests: XCTestCase, @unchecked Sendable {
    func testCompareRequiresCanonicalBaselineAndExplicitCandidateWorkspace() throws {
        let arguments = ["compare", "--baseline-support", "/baseline", "--baseline-attempt", "failed-attempt", "--support-root", "/candidate"]
        let command = try AutomationCLICommand.parse(arguments)
        XCTAssertEqual(command.operation, .compare)
        XCTAssertEqual(try AutomationCLI.comparisonAttempts(command.options["--attempts"]), 3)
        XCTAssertEqual(try AutomationCLI.comparisonAttempts("2"), 2)
        XCTAssertEqual(try AutomationCLI.comparisonAttempts("100"), 100)
        for value in ["0", "-1", "101", "3.0", "03", " 3", "999999999999999999999999999"] {
            XCTAssertThrowsError(try AutomationCLICommand.parse(arguments + ["--attempts", value]))
        }
        for invalid in [["compare"], Array(arguments.dropLast(2)),
                        ["compare", "--baseline-support", "/baseline", "--baseline-attempt", "../escape", "--support-root", "/candidate"],
                        arguments + ["--plan", "/changed-oracle"], arguments + ["--attempts", "3", "--attempts", "2"]] {
            XCTAssertThrowsError(try AutomationCLICommand.parse(invalid))
        }
    }

    func testCanonicalFailureSelectionRetainsFrozenOracleAndRejectsChangedEvidence() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cases = try AutomationCaseStore(root: root.appendingPathComponent("Cases"))
        let plan = plan(), frozen = try await cases.freeze(plan)
        let failed = report(plan: plan, passes: false)
        try await cases.saveAttempt(failed, for: frozen)
        let (stored, original) = try await AutomationCLI.savedAttempt(attemptID: failed.attemptID, supportRoot: root)
        XCTAssertEqual(stored, frozen); XCTAssertEqual(original, failed)
        XCTAssertNoThrow(try AutomationCLI.validateComparisonFailure(stored, original: original))
        var changedPlan = stored.plan
        changedPlan.requirements[0].expected = .bool(false)
        XCTAssertThrowsError(try AutomationCLI.validateComparisonFailure(.init(plan: changedPlan), original: original))
        changedPlan = stored.plan; changedPlan.target.id = "different-target"
        XCTAssertThrowsError(try AutomationCLI.validateComparisonFailure(.init(plan: changedPlan), original: original))
        do {
            _ = try await AutomationCLI.savedAttempt(attemptID: "absent", supportRoot: root)
            XCTFail("A missing canonical attempt was accepted")
        } catch { }
    }

    func testComparisonRejectsPassUnreleasedUncertainAndUnassessedSeed() throws {
        let plan = plan(), frozen = try AutomationFrozenCase(plan: plan)
        XCTAssertThrowsError(try AutomationCLI.validateComparisonFailure(frozen, original: report(plan: plan, passes: true)))
        let failure = report(plan: plan, passes: false)
        for index in 0..<4 {
            var invalid = failure
            if index == 0 { invalid.resourcesReleased = false }
            if index == 1 { invalid.result.subjectDispatchUncertain = true }
            if index == 2 { invalid.result.assessed = false }
            if index == 3 { invalid.result.evidenceComplete = false }
            XCTAssertThrowsError(try AutomationCLI.validateComparisonFailure(frozen, original: invalid))
        }
    }

    func testComparisonRejectsRepeatedFixtureWritesWithoutFrozenSetupChecks() throws {
        var plan = plan()
        plan.execution.effects.insert(.fixtureWrite)
        XCTAssertThrowsError(try AutomationCLI.validateComparisonFailure(.init(plan: plan), original: report(plan: plan, passes: false)))
        plan.execution.effects = [.externalWrite]
        XCTAssertThrowsError(try AutomationCLI.validateComparisonFailure(.init(plan: plan), original: report(plan: plan, passes: false)))
    }

    private func plan() -> AutomationCase {
        .init(id: "comparison", app: .init(logicalID: "fixture", bundleID: "example.Fixture", platform: "macos", productDigest: String(repeating: "a", count: 64)),
            target: .init(id: "fixture", kind: .nativeMac), environmentID: "isolated",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "Complete", effects: [.observe]),
            observations: [.init(id: "observer", kind: .ui, phase: .observe, operation: "Read", effects: [.observe])],
            requirements: [.init(observationID: "observer", expected: .bool(true), proof: .visibleState, justification: "Read persisted result")])
    }
    private func report(plan: AutomationCase, passes: Bool) -> AutomationAttemptReport {
        let observation = AutomationObservation(id: "observer", app: plan.app, target: plan.target,
            environmentID: plan.environmentID, attemptID: "seed", stepID: "observer", route: .ui,
            proof: .visibleState, value: .bool(passes))
        let receipts = [
            AutomationSegmentReceipt(scope: .init(runID: "seed", attemptID: "seed", segmentID: "subject", leaseGeneration: 1),
                app: plan.app, target: plan.target, segmentID: "subject", route: .systemIntent, dispatched: true, completed: true),
            AutomationSegmentReceipt(scope: .init(runID: "seed", attemptID: "seed", segmentID: "observer", leaseGeneration: 2),
                app: plan.app, target: plan.target, segmentID: "observer", route: .ui, dispatched: true, completed: true, observations: [observation])]
        return .init(attemptID: "seed", result: AutomationAssessment.assess(plan: plan, attemptID: "seed",
            subjectDispatched: true, subjectCompleted: true, observations: [observation]), receipts: receipts, resourcesReleased: true)
    }
}
#endif
