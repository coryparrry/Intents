import Foundation

public struct AutomationCampaignLimits: Codable, Equatable, Sendable {
    public var attempts = 100
    public var subjectOperations = 100
    public var setupOperations = 1000
    public var observerOperations = 1000
    public var cleanupOperations = 1000
    public var uiActions = 1000
    public var controllerCalls = 300
    public var wallClockSeconds = 3600
    public init() {}
    public static var firstCampaign: Self { var limits = Self(); limits.attempts = 20; limits.subjectOperations = 20; return limits }
    func validate() throws {
        let values = [attempts, subjectOperations, setupOperations, observerOperations, cleanupOperations, uiActions, controllerCalls, wallClockSeconds]
        guard values.allSatisfy({ $0 >= 0 && $0 <= 100_000 }), attempts > 0, subjectOperations > 0,
              wallClockSeconds > 0 else { throw AutomationContractError.invalidPlan("Invalid campaign limits") }
    }
}
public struct AutomationCampaignUsage: Codable, Equatable, Sendable {
    public var attempts = 0
    public var reservedSubjectOperations = 0
    public var reservedSetupOperations = 0
    public var reservedObserverOperations = 0
    public var reservedCleanupOperations = 0
    public var reservedUIActions = 0
    public var controllerCalls = 0
    public var reservedResourceReleaseOperations = 0
    /// Counts above reserve before dispatch; uncertain operations keep their reservation.
    /// App-model requests remain unknown without correlated app-owned telemetry.
    public var appModelRequests: Int? = nil
    public init() {}
}
public enum AutomationCampaignBudgetError: Error, Equatable { case exhausted(String) }

/// Shared by every actual route/controller in a campaign. No reservation is refunded after ambiguity.
public actor AutomationCampaignBudget {
    public let limits: AutomationCampaignLimits
    public nonisolated let deadline: ContinuousClock.Instant
    private nonisolated let now: @Sendable () -> ContinuousClock.Instant
    private var usage = AutomationCampaignUsage()
    private var operations: Set<String> = []
    public init(limits: AutomationCampaignLimits, now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) throws {
        try limits.validate(); self.limits = limits
        self.now = now
        deadline = now().advanced(by: .seconds(limits.wallClockSeconds))
    }
    public func reserveAttempt(id: String) throws {
        try available(); guard usage.attempts < limits.attempts else { throw AutomationCampaignBudgetError.exhausted("attempts") }
        try unique("attempt:" + id); usage.attempts += 1
    }
    public func reserveOperations(id: String, phase: AutomationSegment.Phase, count: Int, uiActions: Int = 0) throws {
        try available()
        guard count >= 0, count <= 100_000, uiActions >= 0, uiActions <= 100_000 else { throw AutomationContractError.invalidIdentity }
        let used: Int, maximum: Int
        switch phase {
        case .subject: used = usage.reservedSubjectOperations; maximum = limits.subjectOperations
        case .setup: used = usage.reservedSetupOperations; maximum = limits.setupOperations
        case .observe: used = usage.reservedObserverOperations; maximum = limits.observerOperations
        case .cleanup: used = usage.reservedCleanupOperations; maximum = limits.cleanupOperations
        }
        guard count <= maximum - used else { throw AutomationCampaignBudgetError.exhausted(phase.rawValue + " operations") }
        guard uiActions <= limits.uiActions - usage.reservedUIActions else { throw AutomationCampaignBudgetError.exhausted("UI actions") }
        try unique("operation:" + id)
        switch phase {
        case .subject: usage.reservedSubjectOperations += count
        case .setup: usage.reservedSetupOperations += count
        case .observe: usage.reservedObserverOperations += count
        case .cleanup: usage.reservedCleanupOperations += count
        }
        usage.reservedUIActions += uiActions
    }
    public func reserveControllerCall(id: String) throws {
        try available(); guard usage.controllerCalls < limits.controllerCalls else { throw AutomationCampaignBudgetError.exhausted("controller calls") }
        try unique("controller:" + id); usage.controllerCalls += 1
    }
    /// Owned resource release remains permitted after a campaign cap/deadline so expiry cannot strand a booted simulator.
    public func reserveResourceRelease(id: String) throws {
        try unique("release:" + id); usage.reservedResourceReleaseOperations += 1
    }
    public func snapshot() -> AutomationCampaignUsage { usage }
    public func remainingDuration() throws -> Duration { try available(); return now().duration(to: deadline) }
    public func available() throws { try validateDeadline() }
    public nonisolated func validateDeadline() throws {
        try Task.checkCancellation()
        guard now() < deadline else { throw AutomationCampaignBudgetError.exhausted("wall clock") }
    }
    private func unique(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 1024, operations.count < 100_000 else { throw AutomationContractError.invalidIdentity }
        guard operations.insert(id).inserted else { throw AutomationContractError.ambiguousDispatch }
    }
}
