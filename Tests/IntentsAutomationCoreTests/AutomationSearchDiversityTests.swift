import XCTest
@testable import IntentsAutomationCore

final class AutomationSearchDiversityTests: XCTestCase {
    private func mutation(_ id: String, kind: AutomationMutationKind, pair: Bool = false) throws -> AutomationMutationCase {
        let app = AppIdentity(logicalID: "app", bundleID: "example.App", platform: "ios")
        let target = TargetIdentity(id: UUID().uuidString, kind: .simulator)
        let plan = AutomationCase(id: id, app: app, target: target, environmentID: "owned",
            execution: .init(id: "subject", kind: .ui, phase: .subject, operation: "approved"))
        return .init(frozen: try .init(plan: plan), recipeIDs: pair ? ["qualified-one", "qualified-two"] : ["qualified-one"],
            kinds: [kind], requiredCapabilities: ["qualified"], semanticJustification: "Test scheduling only")
    }
    private func report(value: AutomationValue) -> AutomationAttemptReport {
        let app = AppIdentity(logicalID: "app", bundleID: "example.App", platform: "ios")
        let target = TargetIdentity(id: "test", kind: .simulator)
        let fact = AutomationObservation(id: "state", app: app, target: target, environmentID: "owned", attemptID: "attempt",
            stepID: "state", route: .ui, proof: .visibleState, value: value)
        let receipt = AutomationSegmentReceipt(scope: .init(runID: "run", attemptID: "attempt", segmentID: "state", leaseGeneration: 1),
            app: app, target: target, segmentID: "state", route: .ui, dispatched: true, completed: true, observations: [fact])
        return .init(attemptID: "attempt", result: .init(summary: .passed, subjectDispatched: true, subjectCompleted: true,
            assessed: true, evidenceComplete: true, failedObservations: [], missingObservations: []), receipts: [receipt], resourcesReleased: true)
    }
    func testQueueReRanksMeasuredFamiliesAndRepeatedBehaviourReducesPriority() throws {
        let productive = try mutation("productive", kind: .duplicateLabel), repeated = try mutation("repeated", kind: .duplicateLabel)
        let other = try mutation("other", kind: .unrelatedData)
        var queue = AutomationSearchDiversityQueue()
        queue.observeBaseline(report(value: .bool(true)))
        let new = queue.observe(report(value: .bool(false)), mutation: productive)
        XCTAssertEqual(new.newCategories, ["state/visibleState/bool.false"])
        let again = queue.observe(report(value: .bool(false)), mutation: repeated)
        XCTAssertTrue(again.newCategories.isEmpty)
        XCTAssertEqual(queue.next(in: [productive, other])?.frozen.digest, other.frozen.digest)
        XCTAssertEqual(again.priorityNumerator, 1); XCTAssertEqual(again.priorityDenominator, 1)
        let third = queue.observe(report(value: .bool(false)), mutation: repeated)
        XCTAssertEqual(third.priorityNumerator, 1); XCTAssertEqual(third.priorityDenominator, 2)
    }
    func testMeasuredNovelFamilyPrioritizesRemainingPairsButSinglesAlwaysComeFirst() throws {
        let single = try mutation("single", kind: .unrelatedData)
        let rich = try mutation("rich", kind: .duplicateLabel)
        let productivePair = try mutation("productive-pair", kind: .duplicateLabel, pair: true)
        let unexploredPair = try mutation("unexplored-pair", kind: .unrelatedData, pair: true)
        var queue = AutomationSearchDiversityQueue()
        queue.observeBaseline(report(value: .bool(true)))
        var observed = report(value: .bool(false))
        observed.receipts[0].verifiedOutputs = ["response": .enumeration(typeID: "action", value: "selected")]
        let measurement = queue.observe(observed, mutation: rich)
        XCTAssertEqual(measurement.newCategories.count, 2)
        XCTAssertEqual(queue.next(in: [unexploredPair, productivePair])?.frozen.digest, productivePair.frozen.digest)
        XCTAssertEqual(queue.next(in: [productivePair, single])?.frozen.digest, single.frozen.digest)
    }
    func testTieBreakIsDigestStableAndExpectedVerdictsNeverSupplyNovelty() throws {
        let first = try mutation("first", kind: .duplicateLabel), second = try mutation("second", kind: .duplicateLabel)
        let queue = AutomationSearchDiversityQueue(), expected = [first.frozen.digest, second.frozen.digest].sorted().first
        XCTAssertEqual(queue.next(in: [first, second])?.frozen.digest, expected)
        XCTAssertEqual(queue.next(in: [second, first])?.frozen.digest, expected)
        let passed = report(value: .bool(true)); var failed = passed
        failed.result.summary = .assertionFailed; failed.result.failedObservations = ["hidden-oracle"]
        XCTAssertEqual(AutomationSearchDiversityQueue.categories(passed), AutomationSearchDiversityQueue.categories(failed))
        var stale = report(value: .bool(false)); stale.receipts[0].observations[0].fresh = false
        XCTAssertFalse(AutomationSearchDiversityQueue.categories(stale).contains("state/visibleState/bool.false"))
        XCTAssertEqual(AutomationSearchDiversityQueue.categories(report(value: .text("random-fixture-1"))),
                       AutomationSearchDiversityQueue.categories(report(value: .text("random-fixture-2"))))
    }
}
