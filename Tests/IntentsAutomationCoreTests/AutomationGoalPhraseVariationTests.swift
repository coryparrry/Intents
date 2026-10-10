import XCTest
@testable import IntentsAutomationCore

final class AutomationGoalPhraseVariationTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> (AutomationFrozenCase, RunApproval) {
        let app = AppIdentity(logicalID: "selected", bundleID: "example.Selected", platform: "ios")
        let target = TargetIdentity(id: UUID().uuidString, kind: .simulator)
        let approval = RunApproval(runID: "campaign", app: app, target: target, environmentID: "owned", effects: [.observe, .navigate], maximumActions: 30, disposable: true)
        let plan = try AutomationUIOnlyPlanner.compile(app: app, target: target, instruction: "Open tasks", endpoint: "Tasks", approvedText: "Approved input", expectedVisibleText: "Personal task complete", approval: approval, localeIdentifier: "en_GB")
        return (try .init(plan: plan), approval)
    }
    func testApprovedGoalPhraseChangesOnlyWordingAndHasDistinctStableIdentity() throws {
        let (base, _) = try fixture()
        let phrase = try AutomationGoalPhraseVariation.propose(baseline: base, instruction: "Show the task list", semanticJustification: "Native developer approved the same destination")
        try AutomationGoalPhraseVariation.validate(phrase, baseline: base)
        XCTAssertEqual(phrase.frozen.plan.execution.uiProgram?.bindings, base.plan.execution.uiProgram?.bindings)
        XCTAssertEqual(phrase.frozen.plan.observations, base.plan.observations)
        XCTAssertEqual(phrase.frozen.oracleDigest, base.oracleDigest)
        XCTAssertNotEqual(phrase.frozen.digest, base.digest); XCTAssertNotEqual(phrase.frozen.plan.id, base.plan.id)
        let repeated = try AutomationGoalPhraseVariation.propose(baseline: base, instruction: "Show the task list", semanticJustification: "Same declared intent")
        XCTAssertEqual(repeated.frozen.digest, phrase.frozen.digest)
    }
    func testPhraseFlagCannotAuthorizeChangesToOtherContractFields() throws {
        let (base, _) = try fixture()
        let phrase = try AutomationGoalPhraseVariation.propose(baseline: base, instruction: "Show tasks", semanticJustification: "Same destination")
        for field in 0..<8 {
            var candidate = phrase, plan = phrase.frozen.plan
            switch field {
            case 0: plan.execution.uiProgram!.operations[0].goal!.endpoint.value = "Other endpoint"
            case 1: plan.execution.uiProgram!.bindings["approvedText"] = "Changed input"
            case 2: plan.requirements[0].expected = .text("Changed oracle")
            case 3: plan.execution.effects.insert(.fixtureWrite)
            case 4: plan.budget.controllerCalls += 1
            case 5: plan.provenance["ui.locale"] = "fr_FR"
            case 6: plan.observations[0].uiProgram!.operations[0].locator!.value = "Other observer"
            default: plan.app.bundleID = "example.Foreign"
            }
            candidate.frozen = try .init(plan: plan)
            XCTAssertThrowsError(try AutomationGoalPhraseVariation.validate(candidate, baseline: base))
        }
        var inconsistent = base.plan; inconsistent.execution.operation = "Different from goal"
        XCTAssertThrowsError(try AutomationGoalPhraseVariation.propose(baseline: .init(plan: inconsistent), instruction: "Show tasks", semanticJustification: "Same destination"))
    }
    func testSearchRequiresExactApprovalBeforeAnyPhraseTrial() async throws {
        let (base, run) = try fixture()
        let phrase = try AutomationGoalPhraseVariation.propose(baseline: base, instruction: "Show tasks", semanticJustification: "Same destination")
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let search = AutomationFailureSearch(cases: try .init(root: root)), executor = PhraseAdmissionExecutor()
        do {
            _ = try await search.run(baseline: base, mutations: [phrase], approval: .init(run: run, approvedDigests: [base.digest]), capabilities: .init(), executor: executor)
            XCTFail("Unapproved phrase entered execution")
        } catch {}
        let before = await executor.calls; XCTAssertEqual(before, 0)
        let result = try await search.run(baseline: base, mutations: [phrase], approval: .init(run: run, approvedDigests: [base.digest, phrase.frozen.digest]), capabilities: .init(), executor: executor)
        let after = await executor.calls; XCTAssertEqual(after, 1)
        XCTAssertEqual(result.interruptions.count, 1); XCTAssertTrue(result.attempts.isEmpty)
        XCTAssertNil(result.finalReproduction)
    }
}
private actor PhraseAdmissionExecutor: AutomationCampaignAttemptExecutor {
    var calls = 0
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String, budget: AutomationCampaignBudget) throws -> AutomationAttemptReport {
        calls += 1; throw CancellationError()
    }
}
