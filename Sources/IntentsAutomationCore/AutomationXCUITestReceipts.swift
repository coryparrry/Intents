import Foundation
import IntentsAutomationUIHostContracts
import IntentsAutomationDateCodec

/// Canonical terminal failure facts. These do not grant live execution or fixture-reuse authority.
public struct AutomationTerminalUIAssertionFailure: Codable, Equatable, Sendable {
    public var scope: AutomationScope
    public var app: AppIdentity
    public var target: TargetIdentity
    public var planDigest: String
    public var stepID: String
    public var property: String
    public var expected: AutomationValue
    public var terminalReceipt: Data
    public var terminalReceiptDigest: String

    init(scope: AutomationScope, app: AppIdentity, target: TargetIdentity, planDigest: String,
         step: UIHostStep, terminalReceipt: Data) throws {
        guard step.kind == .assert, let property = step.property, let equals = step.equals else {
            throw AutomationContractError.conflictingOperation
        }
        self.scope = scope; self.app = app; self.target = target; self.planDigest = planDigest
        stepID = step.id; self.property = property
        expected = try AutomationHostReceiptImporter.decodeValue(JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(equals)), depth: 0)
        self.terminalReceipt = terminalReceipt; terminalReceiptDigest = AutomationArtifactRegistry.digest(terminalReceipt)
    }

    func validate(receipt: AutomationSegmentReceipt, segment: AutomationSegment, plan: AutomationCase) throws {
        try scope.validate(); try expected.validate()
        guard scope == receipt.scope, app == receipt.app, target == receipt.target,
              receipt.dispatched, !receipt.completed, segment.usesUIControl, receipt.segmentID == segment.id,
              receipt.route == segment.kind, scope.segmentId == segment.id, app == plan.app, target == plan.target,
              planDigest == (try AutomationFrozenCase.planDigest(plan)), terminalReceipt.count <= 1_048_576,
              terminalReceiptDigest == AutomationArtifactRegistry.digest(terminalReceipt),
              let declared = segment.uiProgram?.steps?.first(where: { $0.id == stepID }), declared.kind == .assert,
              declared.property == property, ["label", "value", "exists", "selected"].contains(property), let equals = declared.equals else {
            throw AutomationContractError.conflictingOperation
        }
        let expectedValue = try AutomationHostReceiptImporter.decodeValue(JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(equals)), depth: 0)
        switch (property, expected) {
        case ("label", .text), ("value", .text), ("exists", .bool), ("selected", .bool): break
        default: throw AutomationContractError.conflictingOperation
        }
        let terminal = try JSONDecoder().decode(UIHostStepReceipt.self, from: terminalReceipt)
        guard expected == expectedValue, terminal.schemaVersion == 1, terminal.runID == scope.runId,
              terminal.attemptID == scope.attemptId, terminal.leaseGeneration == scope.leaseGeneration,
              terminal.bundleID == app.bundleID, terminal.productDigest == app.productDigest,
              terminal.planDigest == planDigest, terminal.segmentID == scope.segmentId,
              terminal.stepID == stepID, terminal.kind == .assert, terminal.dispatched, !terminal.completed,
              terminal.error == "assertionFailed", (0..<300).contains(terminal.stepIndex) else {
            throw AutomationContractError.conflictingOperation
        }
    }
}

public struct AutomationXCUITestFailure: Error, Sendable {
    public let receipts: [AutomationSegmentReceipt]
    public let reason: AttemptResult.Summary
    public let resourcesReleased: Bool
    public let subjectDispatchUncertain: Bool
    public init(receipts: [AutomationSegmentReceipt], reason: AttemptResult.Summary, resourcesReleased: Bool, subjectDispatchUncertain: Bool = false) {
        self.receipts = receipts; self.reason = reason; self.resourcesReleased = resourcesReleased
        self.subjectDispatchUncertain = subjectDispatchUncertain
    }
}

public enum AutomationXCUITestReceiptImporter {
    /// A matching XCTest exit alone never creates a completed segment.
    public static func importReceipts(_ data: [Data], uiPlan: UIHostPlan, plan: AutomationCase,
                                      allowPartial: Bool = false) throws -> [AutomationSegmentReceipt] {
        try uiPlan.validate()
        guard uiPlan.planDigest == (try AutomationFrozenCase.planDigest(plan)), uiPlan.bundleID == plan.app.bundleID,
              uiPlan.productDigest == plan.app.productDigest, data.count <= 1000 else { throw AutomationContractError.conflictingOperation }
        var terminal: [Int: UIHostStepReceipt] = [:], dispatched: [Int: UIHostStepReceipt] = [:], terminalData: [Int: Data] = [:]
        for bytes in data {
            guard bytes.count <= 1_048_576 else { throw AutomationContractError.missingEvidence("UI receipt exceeds budget") }
            let receipt = try JSONDecoder().decode(UIHostStepReceipt.self, from: bytes)
            guard receipt.schemaVersion == 1, receipt.runID == uiPlan.runID, receipt.attemptID == uiPlan.attemptID,
                  receipt.leaseGeneration == uiPlan.leaseGeneration, receipt.bundleID == uiPlan.bundleID,
                  receipt.productDigest == uiPlan.productDigest, receipt.planDigest == uiPlan.planDigest,
                  uiPlan.steps.indices.contains(receipt.stepIndex), receipt.dispatched else { throw AutomationContractError.missingEvidence("UI receipt scope mismatch") }
            let step = uiPlan.steps[receipt.stepIndex]
            guard receipt.segmentID == step.segmentID, receipt.stepID == step.id, receipt.kind == step.kind,
                  !receipt.completed || receipt.error == nil else { throw AutomationContractError.missingEvidence("UI receipt operation mismatch") }
            if receipt.completed, [.invokeIntent, .query, .readProperty, .waitFor, .assert].contains(step.kind), receipt.value == nil {
                throw AutomationContractError.missingEvidence("Completed operation is missing its result")
            }
            if receipt.completed || receipt.error != nil {
                guard terminal.updateValue(receipt, forKey: receipt.stepIndex) == nil else { throw AutomationContractError.missingEvidence("Duplicate terminal UI receipt") }
                terminalData[receipt.stepIndex] = bytes
            } else {
                guard receipt.value == nil, dispatched.updateValue(receipt, forKey: receipt.stepIndex) == nil else { throw AutomationContractError.missingEvidence("Duplicate UI dispatch receipt") }
            }
        }
        guard allowPartial || terminal.count == uiPlan.steps.count else { throw AutomationContractError.missingEvidence("UI steps have no exact completed receipts") }
        var ordered: [UIHostStepReceipt] = [], stopped = false
        for index in uiPlan.steps.indices {
            let receipt = terminal[index] ?? dispatched[index]
            if let receipt {
                guard !stopped else { throw AutomationContractError.missingEvidence("UI receipts continue beyond a failed step") }
                ordered.append(receipt); stopped = !receipt.completed
            } else {
                stopped = true
            }
        }
        if !allowPartial { guard !stopped else { throw AutomationContractError.missingEvidence("UI execution did not complete") } }
        var result: [AutomationSegmentReceipt] = []
        for segment in plan.setup + [plan.execution] + plan.observations + plan.cleanup {
            let receipts = ordered.filter { $0.segmentID == segment.id }
            guard !receipts.isEmpty else { continue }
            let expected = uiPlan.steps.filter { $0.segmentID == segment.id }
            let complete = receipts.count == expected.count && receipts.allSatisfy(\.completed)
            let resolved = complete || receipts.contains(where: { $0.value != nil })
                ? try AutomationInputResolver.resolve(segment: segment, receipts: result, plan: plan, runID: uiPlan.runID, attemptID: uiPlan.attemptID)
                : segment
            var values: [String: AutomationValue] = [:]
            for receipt in receipts {
                if let raw = receipt.value {
                    let json = try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(raw))
                    let decoded = try AutomationHostReceiptImporter.decodeValue(json, depth: 0)
                    if let operation = resolved.hostProgram?.operations.first(where: { $0.id == receipt.stepID }), operation.kind == .query {
                        try AutomationEntitySelection.validateQueryOutput(decoded, query: operation)
                    } else if let operation = segment.hostProgram?.operations.first(where: { $0.id == receipt.stepID }), receipt.completed {
                        guard matchesResult(decoded, codec: operation.resultCodec ?? "noValue") else { throw AutomationContractError.missingEvidence("Intent result does not match its frozen codec") }
                    }
                    values[receipt.stepID] = decoded
                }
            }
            let observations: [AutomationObservation]
            if segment.phase == .observe, complete, !values.isEmpty {
                let value = segment.usesUIControl ? .object(values) : values.count == 1 ? values.values.first! : .object(values)
                observations = [.init(id: segment.id, app: plan.app, target: plan.target, environmentID: plan.environmentID,
                                      attemptID: uiPlan.attemptID, stepID: segment.id, route: segment.kind,
                                      proof: segment.kind == .systemQuery ? .appState : .visibleState, value: value)]
            } else { observations = [] }
            result.append(.init(scope: .init(runID: uiPlan.runID, attemptID: uiPlan.attemptID, segmentID: segment.id,
                                            leaseGeneration: uiPlan.leaseGeneration), app: plan.app, target: plan.target,
                                segmentID: segment.id, route: segment.kind, dispatched: true, completed: complete,
                                observations: observations, verifiedOutputs: values, environmentID: plan.environmentID))
            if let failed = receipts.last, !failed.completed, failed.kind == .assert, failed.error == "assertionFailed",
               let bytes = terminalData[failed.stepIndex] {
                let step = uiPlan.steps[failed.stepIndex]
                guard let declared = segment.uiProgram?.steps?.first(where: { $0.id == step.id }),
                      declared.kind == .assert, declared.query == step.query,
                      declared.property == step.property, declared.equals == step.equals else { throw AutomationContractError.conflictingOperation }
                let proof = try AutomationTerminalUIAssertionFailure(scope: result[result.count - 1].scope, app: plan.app, target: plan.target,
                    planDigest: uiPlan.planDigest, step: step, terminalReceipt: bytes)
                try proof.validate(receipt: result[result.count - 1], segment: segment, plan: plan)
                result[result.count - 1].terminalUIAssertionFailure = proof
            }
            if segment.phase == .setup, complete {
                guard AutomationFixtureValidator.validates(receipt: result.last!, segment: resolved, plan: plan,
                                                          runID: uiPlan.runID, attemptID: uiPlan.attemptID) else {
                    throw AutomationContractError.missingEvidence("Completed setup receipt fails its approved precondition")
                }
            }
        }
        return result
    }
    private static func matchesResult(_ value: AutomationValue, codec: String) -> Bool {
        switch (codec, value) {
        case ("noValue", .omission), ("text", .text), ("bool", .bool), ("integer", .integer), ("decimal", .decimal), ("date", .date): return true
        case (let family, .array(let items)): return AutomationCodecRegistry.matchesArray(items, family: family)
        case ("duration", .object): return (try? AutomationDurationInput(taggedValue: value)) != nil
        case ("calendarComponents", .object): return (try? AutomationCalendarInput(taggedValue: value)) != nil
        case ("url", .object): return (try? AutomationURLReference(taggedValue: value)) != nil
        default: return false
        }
    }
}
