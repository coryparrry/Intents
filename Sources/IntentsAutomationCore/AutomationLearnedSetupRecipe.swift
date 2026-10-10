import Foundation

/// An ordered native trace. A policy grant alone never makes this released evidence.
struct AutomationSetupTrace: Sendable {
    var valid = true
    var finished = false
    var operations: [AutomationUIProgram.Operation] = []
    var pending: AutomationUIProgram.Operation?

    mutating func prepare(_ decision: AutomationControllerDecision, request: AutomationControllerRequest) {
        guard valid, !finished, pending == nil else { valid = false; return }
        guard !request.truncated, request.omittedNodes == 0 else { valid = false; return }
        if decision.kind == "finish" { finished = true; return }
        guard operations.count < 29 else { valid = false; return }
        let id = "learned.\(operations.count)"
        if decision.kind == "scroll" {
            pending = .init(id: id, kind: .scroll, direction: decision.direction); return
        }
        guard let node = request.nodes.first(where: { $0.id == decision.node }), !node.secure,
              node.visible, !node.disabled else { valid = false; return }
        let locator: AutomationUIProgram.Locator
        if let identifier = node.testId,
           request.nodes.filter({ $0.testId == identifier }).count == 1 {
            locator = .init(.testId, identifier)
        } else if decision.kind == "tap", node.role == "button", let name = node.name, !name.isEmpty,
                  name.utf16.count < 512,
                  request.nodes.filter({ $0.role == "button" && $0.name == name }).count == 1 {
            locator = .init(.label, name, role: .button)
        } else { valid = false; return }
        switch decision.kind {
        case "tap": pending = .init(id: id, kind: .tap, locator: locator)
        case "fill": pending = .init(id: id, kind: .fillBinding, locator: locator, binding: decision.textBinding)
        default: valid = false
        }
    }
    mutating func consume() {
        guard valid, !finished, let pending else { valid = false; return }
        operations.append(pending); self.pending = nil
    }
    func capture(scope: AutomationScope, goal: AutomationNavigationGoal) -> AutomationControllerSetupCapture? {
        guard valid, finished, pending == nil, !operations.isEmpty, operations.count < 30 else { return nil }
        return .init(scope: scope, operations: operations + [.init(id: "learned.endpoint", kind: .assertEndpoint, locator: goal.endpoint)])
    }
}

/// Neither this capture nor its public live-attempt token can be deserialized.
struct AutomationControllerSetupCapture: Sendable {
    let scope: AutomationScope
    let operations: [AutomationUIProgram.Operation]
    static func unique(_ captures: [Self], scope: AutomationScope) -> Self? {
        let matches = captures.filter { $0.scope == scope }
        return matches.count == 1 ? matches.first : nil
    }
}
public struct AutomationCapturedSetupAttempt: Sendable {
    let live: AutomationLiveRecipeEvidence
    let capture: AutomationControllerSetupCapture
    let bindings: [AutomationFreshFixtureBinding]
    init(live: AutomationLiveRecipeEvidence, capture: AutomationControllerSetupCapture,
         bindings: [AutomationFreshFixtureBinding]) throws {
        try AutomationQualifiedFreshFixture.validateLiveAttempt(bindings: bindings, evidence: live)
        guard capture.scope.runId == live.approval.runID, capture.scope.attemptId == live.report.attemptID,
              live.plan.setup.filter({ $0.id == capture.scope.segmentId }).count == 1,
              let segment = live.plan.setup.first(where: { $0.id == capture.scope.segmentId }),
              segment.phase == .setup, let program = segment.uiProgram, program.operations.count == 1,
              let goal = program.operations.first?.goal,
              capture.operations.last == .init(id: "learned.endpoint", kind: .assertEndpoint, locator: goal.endpoint),
              live.report.receipts.contains(where: { $0.scope == capture.scope && $0.segmentID == segment.id && $0.completed && $0.dispatched }) else {
            throw AutomationContractError.missingEvidence("Learned setup needs its exact completed live segment")
        }
        let resolved = try AutomationInputResolver.resolve(segment: segment, receipts: [], plan: live.plan,
            runID: live.approval.runID, attemptID: live.report.attemptID)
        try AutomationUIProgram(operations: capture.operations, bindings: resolved.uiProgram!.bindings,
            timeoutMilliseconds: program.timeoutMilliseconds).validate(phase: .setup)
        guard capture.operations.dropLast().allSatisfy({ [.tap, .fillBinding, .scroll].contains($0.kind) }) else {
            throw AutomationContractError.missingEvidence("Learned setup contains an unsupported operation")
        }
        self.live = live; self.capture = capture; self.bindings = bindings
    }
}

/// Proposes fresh operations; it grants no execution or fixture freshness authority.
public struct AutomationQualifiedNavigationSetupRecipe: Sendable {
    public let context: AutomationRecipeContext
    public let qualificationAttemptIDs: [String]
    public let qualificationReportDigests: [String]
    private let fixtureDigest: String
    private let segmentID: String
    private let operations: [AutomationUIProgram.Operation]
    public init(attempts: [AutomationCapturedSetupAttempt]) throws {
        guard attempts.count == 2, attempts[0].bindings == attempts[1].bindings,
              attempts[0].capture.scope.segmentId == attempts[1].capture.scope.segmentId,
              attempts[0].capture.operations == attempts[1].capture.operations else {
            throw AutomationContractError.missingEvidence("Learning requires two matching live setup paths")
        }
        let fixture = try AutomationQualifiedFreshFixture(bindings: attempts[0].bindings, evidence: attempts.map(\.live))
        // Never retain an instance-specific selector or endpoint, including entity IDs.
        func entityIDs(_ value: AutomationValue) -> [String] {
            switch value {
            case .entity(_, let id): return [id]
            case .array(let values): return values.flatMap(entityIDs)
            case .object(let fields): return fields.values.flatMap(entityIDs)
            default: return []
            }
        }
        // Only explicitly non-fill context that also participates in the
        // independently checked entity selection can name an existing button.
        let contextBindings = attempts.map { attempt -> [String: String] in
            guard let segment = attempt.live.plan.setup.first(where: { $0.id == attempt.capture.scope.segmentId }),
                  let program = segment.uiProgram, let permittedFill = program.operations.first?.goal?.allowedFillBindings else { return [:] }
            let selectionValues = Set(attempt.bindings.flatMap { binding in
                binding.selection.matchingProperties.values.compactMap { value -> String? in
                    if case .text(let text) = value { return text }; return nil
                }
            })
            return program.bindings.filter { name, value in
                !permittedFill.contains(name) && segment.attemptTextBindings?[name] == nil && selectionValues.contains(value)
            }
        }
        let navigationLabels = Set(contextBindings.flatMap { $0.values }.filter { !$0.isEmpty })
        let instanceValues = attempts.enumerated().flatMap { index, attempt -> [String] in
            let values = attempt.live.plan.setup.flatMap { segment -> [String] in
                let privateBindings = (segment.uiProgram?.bindings ?? [:]).filter { name, _ in
                    segment.id != attempt.capture.scope.segmentId || contextBindings[index][name] == nil
                }
                return Array(privateBindings.values) +
                (segment.attemptTextBindings ?? [:]).values.compactMap { try? AutomationAttemptText.value(prefix: $0, attemptID: attempt.live.report.attemptID) }
            }
            let queriedIDs = attempt.live.report.receipts.filter { $0.route == .systemQuery }
                .flatMap { ($0.verifiedOutputs ?? [:]).values.flatMap(entityIDs) }
            return values + queriedIDs + Array(fixture.qualifiedEntityIDs).flatMap { value in [value, String(value.split(separator: ":", maxSplits: 1).last ?? "")] }
        }.filter { !$0.isEmpty }
        guard attempts[0].capture.operations.allSatisfy({ operation in
            guard let locator = operation.locator else { return true }
            let usesContext = navigationLabels.contains(where: { locator.value.contains($0) })
            let exactContextButton = operation.kind == .tap && locator.kind == .label && locator.role == .button && navigationLabels.contains(locator.value)
            return !instanceValues.contains(where: { locator.value.contains($0) }) &&
                (!usesContext || exactContextButton) &&
                locator.value.range(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#, options: .regularExpression) == nil
        }) else { throw AutomationContractError.missingEvidence("Learned selectors must be independent of attempt records and text") }
        context = fixture.context; fixtureDigest = fixture.fixtureDigest
        qualificationAttemptIDs = fixture.qualificationAttemptIDs; qualificationReportDigests = fixture.qualificationReportDigests
        segmentID = attempts[0].capture.scope.segmentId; operations = attempts[0].capture.operations
    }
    public func propose(plan: AutomationCase, context: AutomationRecipeContext) throws -> AutomationCase {
        try context.validate()
        guard context == self.context, plan.app == context.app, plan.target == context.target,
              plan.environmentID == context.environmentID, plan.provenance["ui.locale"] == context.localeIdentifier,
              try AutomationQualifiedFreshFixture.digest(plan: plan) == fixtureDigest,
              let index = plan.setup.firstIndex(where: { $0.id == segmentID }), let program = plan.setup[index].uiProgram else {
            throw AutomationContractError.missingEvidence("Learned setup context or approved fixture contract changed")
        }
        var proposal = plan
        proposal.setup[index].uiProgram = .init(operations: operations, bindings: program.bindings, timeoutMilliseconds: program.timeoutMilliseconds)
        // Deferred attempt text remains deferred until this new plan's ordinary run approval.
        var validation = proposal.setup[index].uiProgram!
        for key in proposal.setup[index].attemptTextBindings?.keys ?? Dictionary<String, String>().keys { validation.bindings[key] = "fresh-input-validation" }
        try validation.validate(phase: .setup)
        return proposal
    }
}
