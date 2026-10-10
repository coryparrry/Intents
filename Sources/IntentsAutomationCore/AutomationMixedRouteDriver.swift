import Foundation

/// Routes bounded segments while retaining exclusive control until the concrete owner proves release.
public actor AutomationMixedRouteDriver: AutomationResolvedRouteDriver {
    private struct Active {
        let scope: AutomationScope
        let lease: AutomationDeviceLeaseManager.Lease
        let segment: AutomationSegment
        let plan: AutomationCase
        let driver: any AutomationRouteDriver
        var acquiring = true
        var acquired = false
        var executing = false
        var releasing = false
        var revoked = false
    }
    private let ui: any AutomationRouteDriver
    private let apple: any AutomationRouteDriver
    private let siri: (any AutomationRouteDriver)?
    private var active: Active?
    private var lastReleased: (AutomationScope, AutomationDeviceLeaseManager.Lease)?
    public init(ui: any AutomationRouteDriver, apple: any AutomationRouteDriver, siri: (any AutomationRouteDriver)? = nil) {
        self.ui = ui; self.apple = apple; self.siri = siri
    }

    public func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope,
                        lease: AutomationDeviceLeaseManager.Lease) async throws {
        try await acquireAuthorized(plan: plan, segment: segment, scope: scope, lease: lease, authority: nil)
    }
    func acquireResolved(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease,
                         authority: AutomationSegmentResolutionAuthority) async throws {
        try await acquireAuthorized(plan: plan, segment: segment, scope: scope, lease: lease, authority: authority)
    }
    private func acquireAuthorized(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease,
                                   authority: AutomationSegmentResolutionAuthority?) async throws {
        try scope.validate()
        guard active == nil, scope.segmentId == segment.id, scope.runId == lease.runID,
              scope.leaseGeneration == lease.generation, plan.target == lease.target else { throw AutomationContractError.targetBusy }
        let driver: any AutomationRouteDriver
        switch segment.kind {
        case .ui: guard lease.control == .ui else { throw AutomationContractError.unknownLease }; driver = ui
        case .systemIntent, .systemQuery: guard lease.control == .system else { throw AutomationContractError.unknownLease }; driver = apple
        case .siriText:
            guard lease.control == .system, plan.target.kind == .physical, let siri else {
                throw AutomationContractError.missingEvidence("Physical Siri submission driver is unavailable")
            }
            driver = siri
        default: throw AutomationContractError.missingEvidence("No qualified production driver for this segment route")
        }
        guard lastReleased?.0 != scope else { throw AutomationContractError.conflictingOperation }
        active = .init(scope: scope, lease: lease, segment: segment, plan: plan, driver: driver)
        defer { if active?.scope == scope { active?.acquiring = false } }
        if let authority, let resolvedDriver = driver as? any AutomationResolvedRouteDriver {
            try await resolvedDriver.acquireResolved(plan: plan, segment: segment, scope: scope, lease: lease, authority: authority)
        } else { try await driver.acquire(plan: plan, segment: segment, scope: scope, lease: lease) }
        guard active?.scope == scope, active?.lease == lease, active?.revoked == false else { throw AutomationContractError.unknownLease }
        active?.acquired = true
    }
    public func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope,
                        lease: AutomationDeviceLeaseManager.Lease) async throws -> AutomationSegmentReceipt {
        guard let owner = active, owner.scope == scope, owner.lease == lease, owner.segment == segment, owner.plan == plan,
              owner.acquired, !owner.acquiring, !owner.executing, !owner.releasing, !owner.revoked else {
            throw AutomationContractError.unknownLease
        }
        active?.executing = true
        defer { if active?.scope == scope { active?.executing = false } }
        let receipt = try await owner.driver.execute(plan: plan, segment: segment, scope: scope, lease: lease)
        guard active?.scope == scope, active?.lease == lease, active?.revoked == false else { throw AutomationContractError.unknownLease }
        return receipt
    }
    public func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async -> AutomationReleaseProof {
        guard let owner = active else {
            let known = lastReleased?.0 == scope && lastReleased?.1 == lease
            return .init(commandsDrained: known, runnerTerminated: known)
        }
        guard owner.scope == scope, owner.lease == lease, !owner.releasing else { return .init(commandsDrained: false, runnerTerminated: false) }
        active?.revoked = true; active?.releasing = true
        let proof = await owner.driver.release(scope: scope, lease: lease)
        guard let current = active, current.scope == scope, current.lease == lease else { return .init(commandsDrained: false, runnerTerminated: false) }
        let drained = proof.commandsDrained && !current.acquiring && !current.executing
        if drained && proof.runnerTerminated && proof.privatePayloadCleaned {
            lastReleased = (scope, lease); active = nil
        } else { active?.releasing = false }
        return .init(commandsDrained: drained, runnerTerminated: proof.runnerTerminated, privatePayloadCleaned: proof.privatePayloadCleaned)
    }
}
