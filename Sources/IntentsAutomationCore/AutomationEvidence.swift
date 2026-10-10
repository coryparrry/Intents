import Foundation

public struct AutomationObservation: Codable, Equatable, Sendable {
    public enum Proof: String, Codable, Sendable { case visibleState, appState, persistedState, executionReceipt, modelTrace }
    public var id: String
    public var app: AppIdentity
    public var target: TargetIdentity
    public var environmentID: String
    public var attemptID: String
    public var stepID: String
    public var route: AutomationSegment.Kind
    public var collectedAt: Date
    public var fresh: Bool
    public var complete: Bool
    public var proof: Proof
    public var value: AutomationValue
    public var artifact: String?
    public init(id: String, app: AppIdentity, target: TargetIdentity, environmentID: String, attemptID: String, stepID: String,
                route: AutomationSegment.Kind, proof: Proof, value: AutomationValue, fresh: Bool = true, complete: Bool = true) {
        self.id = id; self.app = app; self.target = target; self.environmentID = environmentID; self.attemptID = attemptID
        self.stepID = stepID; self.route = route; self.proof = proof; self.value = value
        self.fresh = fresh; self.complete = complete; collectedAt = Date()
    }
}
public enum AutomationPolicyDenialReason: String, Codable, CaseIterable, Sendable {
    case scopeEnvelope, actionShape, controllerNode, scopeLease, actionMismatch, deadline, budget, routeBusy, routeRevoked, unspecified

    static func from(_ error: Error) -> Self? {
        guard case .remote(let code, let message) = error as? AutomationRPCError, code == -32000 else { return nil }
        return allCases.first { message == "Action denied: " + $0.rawValue }
    }

    public var explanation: String {
        switch self {
        case .scopeEnvelope: "The action no longer matches the approved run."
        case .actionShape: "The action contains unsupported input."
        case .controllerNode: "The selected control no longer matches the approved control."
        case .scopeLease: "This run no longer has control of the device."
        case .actionMismatch: "The action or input differs from what was approved."
        case .deadline: "The time allowed for this action expired."
        case .budget: "The run reached its action or time limit."
        case .routeBusy: "Another permission check is still in progress."
        case .routeRevoked: "Control of the app ended before the action could proceed."
        case .unspecified: "The action was not approved."
        }
    }
}

public struct AttemptResult: Codable, Equatable, Sendable {
    public enum Summary: String, Codable, Sendable {
        case passed, assertionFailed, executedUnassessed, needsReview, invalidFixture, inputUnavailable
        case capabilityUnavailable, permissionRequired, modelUnavailable, cancelled, timedOut, disconnected
        case infrastructureFailed, replayDiverged, unresolved
    }
    public var summary: Summary
    public var subjectDispatched: Bool
    public var subjectDispatchUncertain = false
    public var subjectCompleted: Bool
    public var assessed: Bool
    public var evidenceComplete: Bool
    public var failedObservations: [String]
    public var missingObservations: [String]
    public var policyDenial: AutomationPolicyDenialReason? = nil
}
public enum AutomationAssessment {
    /// Navigation completion and XCTest exit codes deliberately do not enter this API.
    public static func assess(plan: AutomationCase, attemptID: String, subjectDispatched: Bool, subjectCompleted: Bool,
                              observations: [AutomationObservation], receipts: [AutomationSegmentReceipt] = [], runID: String? = nil, termination: AttemptResult.Summary? = nil) -> AttemptResult {
        if !subjectCompleted || !subjectDispatched {
            return .init(summary: termination ?? (subjectDispatched ? .unresolved : .invalidFixture),
                         subjectDispatched: subjectDispatched, subjectCompleted: false, assessed: false,
                         evidenceComplete: false, failedObservations: [], missingObservations: plan.requirements.map { $0.checkID ?? $0.observationID })
        }
        var missing: [String] = []; var failed: [String] = []
        for requirement in plan.requirements {
            let checkID = requirement.checkID ?? requirement.observationID
            let requiredRoute = plan.observations.first(where: { $0.id == requirement.observationID })?.kind
            let candidates = observations.filter {
                $0.id == requirement.observationID && $0.stepID == requirement.observationID && $0.attemptID == attemptID
                && $0.app == plan.app && $0.target == plan.target && $0.environmentID == plan.environmentID
                && $0.proof == requirement.proof && $0.fresh && $0.complete
                && $0.route == requiredRoute
            }
            guard candidates.count == 1 else { missing.append(checkID); continue }
            let value: AutomationValue
            if let predicate = requirement.entityProperty {
                guard let segment = plan.observations.first(where: { $0.id == requirement.observationID }) else { missing.append(checkID); continue }
                let resolved: AutomationSegment
                if segment.inputBindings?.isEmpty == false || segment.hostProgram?.operations.contains(where: { $0.attemptQueryPrefix != nil }) == true {
                    guard let runID, let bound = try? AutomationInputResolver.resolve(segment: segment, receipts: receipts, plan: plan, runID: runID, attemptID: attemptID) else { missing.append(checkID); continue }
                    resolved = bound
                } else { resolved = segment }
                guard let actual = try? predicate.value(observation: candidates[0], segment: resolved) else { missing.append(checkID); continue }
                value = actual
            } else { value = candidates[0].value }
            if value != requirement.expected { failed.append(checkID) }
        }
        let summary: AttemptResult.Summary = !failed.isEmpty ? .assertionFailed : !missing.isEmpty ? .needsReview
            : plan.requirements.isEmpty ? .executedUnassessed : .passed
        return .init(summary: summary, subjectDispatched: subjectDispatched, subjectCompleted: true,
                     assessed: !plan.requirements.isEmpty && missing.isEmpty, evidenceComplete: missing.isEmpty,
                     failedObservations: failed, missingObservations: missing)
    }
}

public struct ScopeCounters: Codable, Equatable, Sendable {
    public var planned = 0, dispatched = 0, completed = 0, assessed = 0, failed = 0, unassessed = 0, notRun = 0, unresolved = 0
    public init() {}
    public mutating func record(_ result: AttemptResult) {
        planned += 1; dispatched += result.subjectDispatched ? 1 : 0; completed += result.subjectCompleted ? 1 : 0
        assessed += result.assessed ? 1 : 0; failed += result.summary == .assertionFailed ? 1 : 0
        unassessed += result.subjectDispatched && !result.assessed ? 1 : 0
        notRun += result.subjectDispatched || result.subjectDispatchUncertain ? 0 : 1
        unresolved += result.summary == .unresolved || result.subjectDispatchUncertain || (result.subjectDispatched && !result.subjectCompleted) ? 1 : 0
    }
}
