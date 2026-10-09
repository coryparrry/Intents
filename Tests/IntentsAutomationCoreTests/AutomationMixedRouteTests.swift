import XCTest
@testable import IntentsAutomationCore

final class AutomationMixedRouteTests: XCTestCase, @unchecked Sendable {
    private func fixture() -> (AutomationCase, RunApproval) {
        let app = AppIdentity(logicalID: "app", bundleID: "example.App", platform: "ios", productDigest: String(repeating: "a", count: 64))
        let plan = AutomationCase(id: "mixed", app: app, target: .init(id: "owned", kind: .simulator), environmentID: "disposable",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "Complete"),
            setup: [.init(id: "setup", kind: .ui, phase: .setup, operation: "Create")],
            observations: [.init(id: "readback", kind: .systemQuery, phase: .observe, operation: "Find")],
            requirements: [.init(observationID: "readback", expected: .bool(true), proof: .persistedState, justification: "Actual independent state")])
        return (plan, .init(runID: "run", app: app, target: plan.target, environmentID: plan.environmentID,
            effects: [.observe], maximumActions: 10, disposable: true, approvedCaseDigest: try! AutomationFrozenCase.planDigest(plan)))
    }
    private func run(omitObservation: Bool = false, releaseUI: Bool = true) async throws -> (AutomationAttemptReport, [String]) {
        let (plan, approval) = fixture(), events = MixedEvents()
        let ui = MixedFixtureDriver(name: "ui", events: events, release: releaseUI)
        let apple = MixedFixtureDriver(name: "apple", events: events, omitObservation: omitObservation)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = AutomationCoordinator(leases: .init(), journal: try .init(url: root.appendingPathComponent("journal.json")))
        let report = try await coordinator.run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt",
            driver: AutomationMixedRouteDriver(ui: ui, apple: apple))
        return (report, await events.values)
    }
    func testConcreteOwnersReleaseBeforeTheNextRouteAcquires() async throws {
        let (report, events) = try await run()
        XCTAssertEqual(report.result.summary, .passed); XCTAssertTrue(report.resourcesReleased)
        XCTAssertEqual(events, ["ui.acquire.setup", "ui.execute.setup", "ui.release.setup",
            "apple.acquire.subject", "apple.execute.subject", "apple.release.subject",
            "apple.acquire.readback", "apple.execute.readback", "apple.release.readback"])
    }
    func testUIReleaseFailureBlocksAppleDispatch() async throws {
        let (report, events) = try await run(releaseUI: false)
        XCTAssertFalse(report.resourcesReleased); XCTAssertFalse(report.result.subjectDispatched)
        XCTAssertEqual(events, ["ui.acquire.setup", "ui.execute.setup", "ui.release.setup"])
    }
    func testUICompletionDoesNotSubstituteForIndependentBusinessEvidence() async throws {
        let (report, _) = try await run(omitObservation: true)
        XCTAssertEqual(report.result.summary, .needsReview); XCTAssertTrue(report.result.subjectCompleted)
    }
    func testForeignPlanLeaseAndReplayedScopeCannotUseAnAcquiredDriver() async throws {
        let (plan, _) = fixture(), events = MixedEvents(), leases = AutomationDeviceLeaseManager()
        let driver = AutomationMixedRouteDriver(ui: MixedFixtureDriver(name: "ui", events: events), apple: MixedFixtureDriver(name: "apple", events: events))
        let lease = try await leases.acquire(runID: "run", target: plan.target, control: .ui)
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "setup", leaseGeneration: lease.generation)
        let segment = plan.setup[0]
        try await driver.acquire(plan: plan, segment: segment, scope: scope, lease: lease)
        var changed = plan; changed.environmentID = "foreign"
        do { _ = try await driver.execute(plan: changed, segment: segment, scope: scope, lease: lease); XCTFail("Foreign plan executed") }
        catch { XCTAssertEqual(error as? AutomationContractError, .unknownLease) }
        var foreign = lease; foreign.generation += 1
        let rejected = await driver.release(scope: scope, lease: foreign); XCTAssertFalse(rejected.commandsDrained)
        let proof = await driver.release(scope: scope, lease: lease); XCTAssertTrue(proof.commandsDrained)
        let repeatProof = await driver.release(scope: scope, lease: lease); XCTAssertTrue(repeatProof.runnerTerminated)
        do { try await driver.acquire(plan: plan, segment: segment, scope: scope, lease: lease); XCTFail("Replayed scope acquired") }
        catch { XCTAssertEqual(error as? AutomationContractError, .conflictingOperation) }
        let history = await events.values; XCTAssertEqual(history, ["ui.acquire.setup", "ui.release.setup"])
    }
    func testCleanupFailureForwardsProcessProofButRetainsOwner() async throws {
        let (plan, _) = fixture(), events = MixedEvents(), leases = AutomationDeviceLeaseManager()
        let driver = AutomationMixedRouteDriver(ui: MixedFixtureDriver(name: "ui", events: events, privatePayloadCleaned: false),
            apple: MixedFixtureDriver(name: "apple", events: events))
        let lease = try await leases.acquire(runID: "run", target: plan.target, control: .ui)
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "setup", leaseGeneration: lease.generation)
        try await driver.acquire(plan: plan, segment: plan.setup[0], scope: scope, lease: lease)
        let proof = await driver.release(scope: scope, lease: lease)
        XCTAssertTrue(proof.commandsDrained); XCTAssertTrue(proof.runnerTerminated); XCTAssertFalse(proof.privatePayloadCleaned)
        do { try await driver.acquire(plan: plan, segment: plan.setup[0], scope: scope, lease: lease); XCTFail("Uncleaned owner replaced") } catch {}
        let history = await events.values; XCTAssertEqual(history, ["ui.acquire.setup", "ui.release.setup"])
    }
    func testReleaseDuringAcquireCannotClaimDrainOrResurrectOwnership() async throws { try await checkLateContinuation(acquiring: true) }
    func testReleaseDuringExecuteCannotClaimDrainOrPromoteLateReceipt() async throws { try await checkLateContinuation(acquiring: false) }
    private func checkLateContinuation(acquiring: Bool) async throws {
        let (plan, _) = fixture(), events = MixedEvents(), leases = AutomationDeviceLeaseManager()
        let ui = MixedFixtureDriver(name: "ui", events: events, holdAcquire: acquiring, holdExecute: !acquiring)
        let driver = AutomationMixedRouteDriver(ui: ui, apple: MixedFixtureDriver(name: "apple", events: events))
        let lease = try await leases.acquire(runID: "run", target: plan.target, control: .ui)
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "setup", leaseGeneration: lease.generation)
        let segment = plan.setup[0]
        if !acquiring { try await driver.acquire(plan: plan, segment: segment, scope: scope, lease: lease) }
        let task = Task {
            if acquiring { try await driver.acquire(plan: plan, segment: segment, scope: scope, lease: lease) }
            else { _ = try await driver.execute(plan: plan, segment: segment, scope: scope, lease: lease) }
        }
        let expected = "ui." + (acquiring ? "acquire" : "execute") + ".setup"
        var reached = false
        for _ in 0..<100 {
            if await events.values.contains(expected) { reached = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(reached)
        let early = await driver.release(scope: scope, lease: lease); XCTAssertFalse(early.commandsDrained)
        await ui.open()
        do { try await task.value; XCTFail("Revoked work became authoritative") }
        catch { XCTAssertEqual(error as? AutomationContractError, .unknownLease) }
        let final = await driver.release(scope: scope, lease: lease); XCTAssertTrue(final.commandsDrained)
        XCTAssertTrue(final.runnerTerminated)
    }
}
private actor MixedEvents {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
private actor MixedFixtureDriver: AutomationRouteDriver {
    let name: String, events: MixedEvents, releases: Bool, omitObservation: Bool, privatePayloadCleaned: Bool
    var holdAcquire: Bool, holdExecute: Bool
    init(name: String, events: MixedEvents, release: Bool = true, privatePayloadCleaned: Bool = true, omitObservation: Bool = false, holdAcquire: Bool = false, holdExecute: Bool = false) {
        self.name = name; self.events = events; releases = release; self.omitObservation = omitObservation; self.privatePayloadCleaned = privatePayloadCleaned
        self.holdAcquire = holdAcquire; self.holdExecute = holdExecute
    }
    func open() { holdAcquire = false; holdExecute = false }
    func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws {
        await events.append(name + ".acquire." + segment.id)
        while holdAcquire { try await Task.sleep(for: .milliseconds(10)) }
    }
    func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws -> AutomationSegmentReceipt {
        await events.append(name + ".execute." + segment.id)
        while holdExecute { try await Task.sleep(for: .milliseconds(10)) }
        let observations: [AutomationObservation] = segment.phase == .observe && !omitObservation ? [.init(id: segment.id,
            app: plan.app, target: plan.target, environmentID: plan.environmentID, attemptID: scope.attemptId, stepID: segment.id,
            route: segment.kind, proof: .persistedState, value: .bool(true))] : []
        return .init(scope: scope, app: plan.app, target: plan.target, segmentID: segment.id, route: segment.kind,
            dispatched: true, completed: true, observations: observations, environmentID: plan.environmentID)
    }
    func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async -> AutomationReleaseProof {
        await events.append(name + ".release." + scope.segmentId)
        return .init(commandsDrained: true, runnerTerminated: releases, privatePayloadCleaned: privatePayloadCleaned)
    }
}
