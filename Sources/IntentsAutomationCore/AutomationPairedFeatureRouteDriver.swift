import Foundation

/// Adapts the existing authenticated feature client to the campaign lease and journal.
/// A timeout/cancel has no remote drain proof and therefore cannot release ownership.
public actor AutomationPairedFeatureRouteDriver: AutomationRouteDriver {
    private struct Active {
        let plan: AutomationCase
        let segment: AutomationSegment
        let scope: AutomationScope
        let lease: AutomationDeviceLeaseManager.Lease
        var acquired = false
        var executing = false
        var issued = false
        var dispatched = false
        var finished = false
        var revoked = false
    }
    private struct Response {
        let attemptID: String
        let runID: String
        let program: AutomationPairedFeatureProgram
        let response: String
    }
    private let client: any AutomationPairedFeatureClient
    private let artifacts: AutomationArtifactRegistry
    private var active: Active?
    private var response: Response?
    public init(client: any AutomationPairedFeatureClient, artifacts: AutomationArtifactRegistry) { self.client = client; self.artifacts = artifacts }
    public func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws {
        try scope.validate()
        guard active == nil, let program = segment.pairedProgram, lease.control == .system, lease.target == plan.target,
              scope.runId == lease.runID, scope.segmentId == segment.id, scope.leaseGeneration == lease.generation,
              UUID(uuidString: scope.runId) != nil,
              (plan.setup + [plan.execution] + plan.observations + plan.cleanup).contains(segment) else { throw AutomationContractError.invalidIdentity }
        try program.validate(segment: segment, target: plan.target)
        active = .init(plan: plan, segment: segment, scope: scope, lease: lease)
        do {
            try await client.validate(program: program, app: plan.app)
            guard active?.revoked == false else { throw AutomationContractError.unknownLease }
            if program.mode == .readResponse {
                guard let response, response.attemptID == scope.attemptId, response.runID == scope.runId,
                      response.program == program.executionIdentity else { throw AutomationContractError.missingEvidence("No matching completed feature response") }
            }
            active?.acquired = true
        } catch { active?.finished = true; throw error }
    }
    public func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws -> AutomationSegmentReceipt {
        guard let owner = active, owner.acquired, !owner.executing, !owner.issued, !owner.revoked,
              owner.plan == plan, owner.segment == segment, owner.scope == scope, owner.lease == lease,
              let program = segment.pairedProgram, let runID = UUID(uuidString: scope.runId) else { throw AutomationContractError.unknownLease }
        active?.executing = true; active?.issued = true
        defer { active?.executing = false }
        var observations: [AutomationObservation] = [], value: String?, completed = true
        if program.mode == .execute {
            try await client.validate(program: program, app: plan.app)
            try Task.checkCancellation()
            guard active?.revoked == false else { throw AutomationContractError.unknownLease }
            let requestID = UUID()
            active?.dispatched = true
            let reply = try await client.execute(program: program, app: plan.app, requestID: requestID, runID: runID, timeout: .seconds(min(120, plan.budget.wallClockSeconds)))
            guard reply.requestID == requestID, (reply.response != nil) != (reply.failure != nil) else { throw AutomationContractError.ambiguousDispatch }
            active?.finished = true
            guard (reply.response?.utf16.count ?? 0) <= 32_768, (reply.failure?.utf8.count ?? 0) <= 4096 else {
                throw AutomationContractError.missingEvidence("The paired response exceeded the retained evidence limit")
            }
            try await client.validate(program: program, app: plan.app)
            if let text = reply.response {
                response = .init(attemptID: scope.attemptId, runID: scope.runId, program: program.executionIdentity, response: text)
                value = text
            } else { completed = false; value = reply.failure }
        } else {
            guard let response, response.attemptID == scope.attemptId, response.runID == scope.runId,
                  response.program == program.executionIdentity else { throw AutomationContractError.conflictingOperation }
            value = response.response; active?.finished = true
        }
        guard active?.revoked == false, let value else { throw AutomationContractError.unknownLease }
        let artifact = try await artifacts.store(data: JSONEncoder().encode(["response": value, "feature": program.featureID, "version": program.featureVersion, "registration": program.registrationDigest]), name: "paired-\(lease.generation).json", scope: scope)
        if program.mode == .readResponse {
            var observation = AutomationObservation(id: segment.id, app: plan.app, target: plan.target, environmentID: plan.environmentID,
                attemptID: scope.attemptId, stepID: segment.id, route: .pairedFeature, proof: .appState, value: .text(value))
            observation.artifact = artifact.handle; observations = [observation]
        }
        return .init(scope: scope, app: plan.app, target: plan.target, segmentID: segment.id, route: .pairedFeature, dispatched: true,
            completed: completed, observations: observations, artifact: artifact.handle, environmentID: plan.environmentID)
    }
    public func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async -> AutomationReleaseProof {
        guard let owner = active, owner.scope == scope, owner.lease == lease else { return .init(commandsDrained: false, runnerTerminated: false) }
        active?.revoked = true
        let drained = !owner.executing && (!owner.dispatched || owner.finished)
        if drained { active = nil }
        return .init(commandsDrained: drained, runnerTerminated: drained)
    }
}

#if os(macOS)
public enum AutomationPairedFeatureCampaign {
    public static func hasAnyRetainedOwnership(supportRoot: URL) async throws -> Bool {
        let leases = try AutomationDeviceLeaseManager(storeURL: supportRoot.appendingPathComponent("target-leases.json"))
        return try await leases.recoveryRecords().contains { $0.target.kind == .pairedRunner }
    }
    public static func hasRetainedOwnership(target: TargetIdentity, supportRoot: URL) async throws -> Bool {
        let leases = try AutomationDeviceLeaseManager(storeURL: supportRoot.appendingPathComponent("target-leases.json"))
        return try await !leases.campaignAbsent(target: target)
    }
    public static func run(plan: AutomationCase, approval: RunApproval, attemptID: String, supportRoot: URL,
                           client: any AutomationPairedFeatureClient) async throws -> AutomationAttemptReport {
        let segments = plan.setup + [plan.execution] + plan.observations + plan.cleanup
        guard plan.target.kind == .pairedRunner, segments.allSatisfy({ $0.kind == .pairedFeature }), plan.setup.isEmpty, plan.cleanup.isEmpty,
              approval.approvedCaseDigest == (try AutomationFrozenCase.planDigest(plan)), UUID(uuidString: approval.runID) != nil else { throw AutomationContractError.invalidPlan("Paired execution needs one exact approved registered feature") }
        let capabilities = CapabilityProfile(records: ["paired.feature.execute": .init(state: .available, reason: "Existing authenticated registered feature", probeVersion: "paired-v1", evidence: [plan.execution.pairedProgram?.registrationDigest ?? ""])])
        try PlanValidator.validate(plan, approval: approval, capabilities: capabilities)
        let cases = try AutomationCaseStore(root: supportRoot.appendingPathComponent("Cases")), frozen = try await cases.freeze(plan)
        let leases = try AutomationDeviceLeaseManager(storeURL: supportRoot.appendingPathComponent("target-leases.json"))
        let root = supportRoot.appendingPathComponent(attemptID)
        guard UUID(uuidString: attemptID) != nil, !FileManager.default.fileExists(atPath: root.path) else { throw AutomationContractError.conflictingOperation }
        let artifacts = try AutomationArtifactRegistry(root: root.appendingPathComponent("artifacts"))
        let journal = try AutomationJournal(url: root.appendingPathComponent("journal.json"))
        let paired = AutomationPairedFeatureRouteDriver(client: client, artifacts: artifacts)
        let unavailable = AutomationUnavailableRouteDriver()
        let driver = AutomationMixedRouteDriver(apple: unavailable, paired: paired)
        let report = try await AutomationCoordinator(leases: leases, journal: journal).run(plan: plan, approval: approval, capabilities: capabilities, attemptID: attemptID, driver: driver)
        let store = try AutomationDurableFile(url: root.appendingPathComponent("report.json"), maximumBytes: 16 * 1024 * 1024)
        try store.withLock { try store.write(JSONEncoder().encode(report)) }
        try await cases.saveAttempt(report, for: frozen)
        return report
    }
}
private struct AutomationUnavailableRouteDriver: AutomationRouteDriver {
    func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws { throw AutomationContractError.missingEvidence("No approved device mapping for this registered runner") }
    func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws -> AutomationSegmentReceipt { throw AutomationContractError.missingEvidence("No approved device mapping") }
    func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async -> AutomationReleaseProof { .init(commandsDrained: true, runnerTerminated: true) }
}
#endif
