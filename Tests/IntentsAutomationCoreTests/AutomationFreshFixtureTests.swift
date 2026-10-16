import XCTest
@testable import IntentsAutomationCore

struct FreshFixtureTestData: Sendable {
    var plan: AutomationCase
    var approval: RunApproval
    var bindings: [AutomationFreshFixtureBinding]
    init(plan existing: AutomationCase? = nil, runID: String = "before") throws {
        let selection: (String) -> AutomationEntitySelection = { .init(typeID: "TaskEntity", matchingProperties: ["title": .text("Send invoice"), "owner": .text($0)]) }
        bindings = ["Personal", "Work"].map { .init(producerSegmentID: "lookup", outputID: "tasks", selection: selection($0)) }
        if let existing { plan = existing }
        else {
            let app = AppIdentity(logicalID: "fixture", bundleID: "example.Fixture", platform: "ios", productDigest: String(repeating: "a", count: 64))
            var ui = AutomationSegment(id: "create", kind: .ui, phase: .setup, operation: "create", effects: [.observe, .navigate, .fixtureWrite], lifecycle: .persistedStateAcrossSegments)
            ui.uiProgram = .init(operations: [.init(id: "fill", kind: .fillBinding, locator: .init(.testId, "title"), binding: "title")], bindings: ["title": "Send invoice"])
            var lookup = AutomationSegment(id: "lookup", kind: .systemQuery, phase: .setup, operation: "lookup", lifecycle: .persistedStateAcrossSegments)
            lookup.hostProgram = .init(operations: [.init(id: "tasks", kind: .query, typeID: "TaskEntity", queryText: "Send invoice", properties: ["title": "text", "owner": "text", "completed": "bool"])])
            var subject = AutomationSegment(id: "subject", kind: .systemIntent, phase: .subject, operation: "CompleteTaskIntent", effects: [.observe, .fixtureWrite], lifecycle: .persistedStateAcrossSegments)
            subject.hostProgram = .init(operations: [.init(id: "complete", kind: .invoke, typeID: "CompleteTaskIntent", resultCodec: "noValue")])
            subject.inputBindings = [.init(producerSegmentID: "lookup", outputID: "tasks", destination: .hostParameter, operationID: "complete", name: "task", uniqueEntity: selection("Personal"))]
            var observer = lookup; observer.id = "state"; observer.phase = .observe
            let check: (String, String, Bool) -> AutomationRequirement = { owner, source, value in
                .init(observationID: source, expected: .bool(value), proof: .appState, justification: "Unit positive owned record", checkID: source + "." + owner,
                      entityProperty: .init(operationID: "tasks", selection: selection(owner), property: "completed"))
            }
            plan = .init(id: "fresh-fixture", app: app, target: .init(id: "owned", kind: .simulator), environmentID: "unit",
                execution: subject, setup: [ui, lookup], observations: [observer], requirements: [check("Personal", "state", true), check("Work", "state", false)],
                setupChecks: [check("Personal", "lookup", false), check("Work", "lookup", false)])
            plan.provenance["ui.locale"] = "en_GB"
        }
        if !plan.execution.requiredCapabilities.contains("apple.codec.entity") { plan.execution.requiredCapabilities.append("apple.codec.entity") }
        approval = .init(runID: runID, app: plan.app, target: plan.target, environmentID: plan.environmentID,
            effects: [.observe, .navigate, .fixtureWrite], maximumActions: 20, disposable: true, approvedCaseDigest: try AutomationFrozenCase.planDigest(plan))
    }
    func records(prefix: String, completed: Bool) -> AutomationValue {
        .array(["Personal", "Work"].map { owner in .object(["entity": .entity(typeID: "TaskEntity", value: prefix + "-" + owner),
            "properties": .object(["title": .text("Send invoice"), "owner": .text(owner), "completed": .bool(owner == "Personal" && completed)])]) })
    }
    func report(id: String, prefix: String, completed: Bool) -> AutomationAttemptReport {
        let observation = AutomationObservation(id: "state", app: plan.app, target: plan.target, environmentID: plan.environmentID, attemptID: id, stepID: "state", route: .systemQuery, proof: .appState, value: records(prefix: prefix, completed: completed))
        let segments = plan.setup + [plan.execution] + plan.observations
        let receipts = segments.enumerated().map { index, segment in AutomationSegmentReceipt(scope: .init(runID: approval.runID, attemptID: id, segmentID: segment.id, leaseGeneration: plan.provenance["ui.backend"] == "xcuitest" ? 1 : index + 1),
            app: plan.app, target: plan.target, segmentID: segment.id, route: segment.kind, dispatched: true, completed: true,
            observations: segment.id == "state" ? [observation] : [], verifiedOutputs: segment.id == "lookup" ? ["tasks": records(prefix: prefix, completed: false)] : nil, environmentID: plan.environmentID) }
        return .init(attemptID: id, result: AutomationAssessment.assess(plan: plan, attemptID: id, subjectDispatched: true, subjectCompleted: true, observations: [observation]), receipts: receipts, resourcesReleased: true)
    }
}
