import XCTest
@testable import IntentsAutomationCore

final class AutomationSubjectPhraseVariationTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> (AutomationFrozenCase, RunApproval) {
        let app = AppIdentity(logicalID: "selected", bundleID: "example.AI", platform: "ios")
        let target = TargetIdentity(id: UUID().uuidString, kind: .simulator)
        let approval = RunApproval(runID: "phrasing", app: app, target: target, environmentID: "owned",
            effects: [.observe, .navigate], maximumActions: 30, disposable: true)
        let plan = try AutomationUIOnlyPlanner.compile(app: app, target: target, instruction: "Submit the approved request to AI",
            endpoint: "AI response", approvedText: "Show my completed tasks", expectedVisibleText: "Completed tasks",
            approval: approval, localeIdentifier: "en_GB")
        return (try .init(plan: plan), approval)
    }
    func testSubjectRequestVariesOnlyExplicitFrozenBindingAndKeepsControllerFixed() throws {
        let (baseline, _) = try fixture()
        let phrase = try AutomationSubjectPhraseVariation.propose(baseline: baseline, slot: .uiRequestBinding("approvedText"),
            request: "List tasks I have completed", semanticJustification: "Developer reviewed the same completed-task request")
        try AutomationSubjectPhraseVariation.validate(phrase, baseline: baseline)
        XCTAssertEqual(phrase.frozen.plan.execution.operation, baseline.plan.execution.operation)
        XCTAssertEqual(phrase.frozen.plan.execution.uiProgram?.operations, baseline.plan.execution.uiProgram?.operations)
        XCTAssertEqual(phrase.frozen.plan.execution.uiProgram?.bindings["approvedText"], "List tasks I have completed")
        XCTAssertEqual(phrase.frozen.plan.observations, baseline.plan.observations)
        XCTAssertEqual(phrase.frozen.oracleDigest, baseline.oracleDigest)
        let repeated = try AutomationSubjectPhraseVariation.propose(baseline: baseline, slot: .uiRequestBinding("approvedText"),
            request: "List tasks I have completed", semanticJustification: "Another explanation of the same approval")
        XCTAssertEqual(phrase.frozen.digest, repeated.frozen.digest)
        XCTAssertThrowsError(try AutomationGoalPhraseVariation.validate(phrase, baseline: baseline))
    }
    func testSubjectPhraseFlagCannotChangeRouteOracleBindingsEffectsOrBudgets() throws {
        let (baseline, _) = try fixture()
        let phrase = try AutomationSubjectPhraseVariation.propose(baseline: baseline, slot: .uiRequestBinding("approvedText"),
            request: "List tasks I have completed", semanticJustification: "Same meaning")
        for field in 0..<9 {
            var changed = phrase, plan = phrase.frozen.plan
            switch field {
            case 0: plan.execution.kind = .siriText
            case 1: plan.execution.operation = "Changed controller instruction"
            case 2: plan.execution.uiProgram!.operations[0].goal!.endpoint.value = "Another destination"
            case 3: plan.execution.uiProgram!.bindings["other"] = "Extra input"
            case 4: plan.requirements[0].expected = .text("Another oracle")
            case 5: plan.observations[0].operation = "Another observer"
            case 6: plan.execution.effects.insert(.fixtureWrite)
            case 7: plan.budget.controllerCalls += 1
            default: plan.execution.inputBindings = [.init(producerSegmentID: "setup", outputID: "name", destination: .uiBinding, name: "approvedText")]
            }
            changed.frozen = try .init(plan: plan)
            XCTAssertThrowsError(try AutomationSubjectPhraseVariation.validate(changed, baseline: baseline))
        }
        for request in ["", "Show my completed tasks", String(repeating: "x", count: 2049), "bad\0request"] {
            XCTAssertThrowsError(try AutomationSubjectPhraseVariation.propose(baseline: baseline, slot: .uiRequestBinding("approvedText"), request: request, semanticJustification: "Same meaning"))
        }
        XCTAssertThrowsError(try AutomationSubjectPhraseVariation.propose(baseline: baseline, slot: .uiRequestBinding("missing"), request: "Another phrase", semanticJustification: "Same meaning"))
    }
    func testSiriPhraseFreezesRecognizedTextWithoutChangingRequiredRoute() throws {
        let (original, _) = try fixture()
        var plan = original.plan
        plan.target = .init(id: "00000001-0000000000000001", kind: .physical)
        plan.execution = .init(id: "siri", kind: .siriText, phase: .subject, operation: "submitRecognizedText",
            requiredCapabilities: ["siri.recognizedText.api"], effects: [.navigate], lifecycle: .persistedStateAcrossSegments)
        plan.execution.siriProgram = .init(request: "Show my completed tasks")
        let baseline = try AutomationFrozenCase(plan: plan)
        let phrase = try AutomationSubjectPhraseVariation.propose(baseline: baseline, slot: .siriRecognizedText,
            request: "List completed tasks", semanticJustification: "Same approved task filter")
        XCTAssertEqual(phrase.frozen.plan.execution.kind, .siriText)
        XCTAssertEqual(phrase.frozen.plan.execution.siriProgram?.request, "List completed tasks")
        XCTAssertEqual(phrase.frozen.plan.execution.requiredCapabilities, baseline.plan.execution.requiredCapabilities)
        XCTAssertNotEqual(phrase.frozen.plan.execution.siriProgram?.requestDigest, baseline.plan.execution.siriProgram?.requestDigest)
        try AutomationSubjectPhraseVariation.validate(phrase, baseline: baseline)
    }
    func testExactApprovalAndPhraseMarkerAreRequiredBeforeAnySubjectDispatch() async throws {
        let (baseline, run) = try fixture()
        let phrase = try AutomationSubjectPhraseVariation.propose(baseline: baseline, slot: .uiRequestBinding("approvedText"),
            request: "List completed tasks", semanticJustification: "Same approved task filter")
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let search = AutomationFailureSearch(cases: try .init(root: root)), executor = SubjectPhraseAdmissionExecutor()
        do {
            _ = try await search.run(baseline: baseline, mutations: [phrase], approval: .init(run: run, approvedDigests: [baseline.digest]), capabilities: .init(), executor: executor)
            XCTFail("Unapproved subject phrase entered execution")
        } catch {}
        var unmarked = phrase; unmarked.subjectPhraseSlot = nil
        unmarked.recipeIDs = ["fake"]; unmarked.requiredCapabilities = ["fake"]
        do {
            _ = try await search.run(baseline: baseline, mutations: [unmarked], approval: .init(run: run, approvedDigests: [baseline.digest, phrase.frozen.digest]),
                capabilities: .init(records: ["fake": .init(state: .available, reason: "Qualified test recipe", probeVersion: "test", evidence: [])]), executor: executor)
            XCTFail("Unmarked request change entered execution")
        } catch {}
        let rejectedCalls = await executor.calls; XCTAssertEqual(rejectedCalls, 0)
        do {
            _ = try await search.run(baseline: baseline, mutations: [phrase], approval: .init(run: run, approvedDigests: [baseline.digest, phrase.frozen.digest]), capabilities: .init(), executor: executor)
            XCTFail("UI request trial without qualified session isolation was admitted")
        } catch {}
        let admittedCalls = await executor.calls; XCTAssertEqual(admittedCalls, 0)
    }
}

private actor SubjectPhraseAdmissionExecutor: AutomationCampaignAttemptExecutor {
    var calls = 0
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String, budget: AutomationCampaignBudget) throws -> AutomationAttemptReport {
        calls += 1; throw CancellationError()
    }
}
