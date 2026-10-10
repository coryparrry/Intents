import Foundation

public enum AutomationEffect: String, Codable, Sendable { case observe, navigate, fixtureWrite, externalWrite, reset }
public struct RunApproval: Codable, Equatable, Sendable {
    public var runID: String
    public var app: AppIdentity
    public var target: TargetIdentity
    public var environmentID: String
    public var effects: Set<AutomationEffect>
    public var maximumActions: Int
    public var disposable: Bool
    public var approvedCaseDigest: String?
    public init(runID: String, app: AppIdentity, target: TargetIdentity, environmentID: String,
                effects: Set<AutomationEffect>, maximumActions: Int, disposable: Bool, approvedCaseDigest: String? = nil) {
        self.runID = runID; self.app = app; self.target = target; self.environmentID = environmentID
        self.effects = effects; self.maximumActions = maximumActions; self.disposable = disposable; self.approvedCaseDigest = approvedCaseDigest
    }
    public func permits(app: AppIdentity, target: TargetIdentity, environmentID: String, effect: AutomationEffect, actions: Int) -> Bool {
        self.app == app && self.target == target && self.environmentID == environmentID && effects.contains(effect)
        && actions < maximumActions && (effect != .reset || disposable)
    }
}

public enum AutomationContractError: Error, Equatable {
    case targetBusy, unknownLease, commandsPending, terminationUnverified, invalidIdentity
    case conflictingOperation, ambiguousDispatch, invalidPlan(String), missingEvidence(String)
}
