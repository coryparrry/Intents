#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

/// Exercises native campaign continuation with synthetic host facts and an injected
/// reader. These tests cannot qualify actual XCTest child-process closure.
final class AutomationDurableStateCampaignIntegrationTests: XCTestCase {
    private func fixture() throws -> (AutomationCase, RunApproval) {
        let profile = AutomationDurableStateProfile.registered[0]
        var app = AppIdentity(logicalID: "fixture", bundleID: profile.bundleID, platform: "macos",
            productDigest: String(repeating: "a", count: 64))
        app.canonicalBundlePath = "/fixture/Product.app"; app.sourceManifestDigest = String(repeating: "b", count: 64)
        let target = TargetIdentity(id: "host-macos-local", kind: .nativeMac, loginSession: "durable-campaign-test")
        let reader = AutomationDurableStateReader(profileID: profile.id, catalogDigest: String(repeating: "c", count: 64),
            hostProductDigest: String(repeating: "d", count: 64), hostXctestrunDigest: String(repeating: "e", count: 64),
            app: app, target: target, environmentID: "fixture", sourceManifestPath: "/fixture/source-manifest.json",
            sourceFiles: Dictionary(uniqueKeysWithValues: profile.sourceDigests.filter { $0.key.hasSuffix(".swift") }
                .map { ("/fixture/source/" + $0.key, $0.value) }), declaration: profile.schema())
        var subject = AutomationSegment(id: "subject", kind: .systemIntent, phase: .subject, operation: "Complete",
            lifecycle: .persistedStateAcrossSegments)
        subject.hostProgram = .init(operations: [.init(id: "complete", kind: .invoke, typeID: "CompleteIntent", resultCodec: "noValue")])
        var observer = AutomationSegment(id: "read", kind: .systemQuery, phase: .observe, operation: "Read independently",
            lifecycle: .persistedStateAcrossSegments)
        observer.hostProgram = .init(operations: [.init(id: "records", kind: .query, typeID: profile.entityTypeID,
            queryIDs: ["selected"], properties: profile.properties)])
        let requirement = AutomationRequirement(observationID: observer.id, expected: .bool(true), proof: .appState,
            justification: "Developer reviewed the saved state", checkID: "saved", entityProperty: .init(operationID: "records",
                selection: .init(typeID: profile.entityTypeID, matchingProperties: ["owner": .text("Work")]), property: "completed"))
        var plan = AutomationCase(id: "durable-campaign", app: app, target: target, environmentID: "fixture",
            execution: subject, observations: [observer], requirements: [requirement])
        plan.provenance = ["catalog": reader.catalogDigest, "apple.macHostProductDigest": reader.hostProductDigest,
            "apple.macXctestrunDigest": reader.hostXctestrunDigest]
        plan = try reader.applying(to: plan)
        var approval = RunApproval(runID: "run", app: app, target: target, environmentID: "fixture",
            effects: [.observe], maximumActions: 100, disposable: true)
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        return (plan, approval)
    }

    private func hostReceipt(_ plan: AutomationCase, generation: Int = 1) -> AutomationSegmentReceipt {
        .init(scope: .init(runID: "run", attemptID: "attempt", segmentID: plan.execution.id, leaseGeneration: generation),
            app: plan.app, target: plan.target, segmentID: plan.execution.id, route: plan.execution.kind,
            dispatched: true, completed: true, environmentID: plan.environmentID)
    }

    private func resources() throws -> (AutomationDeviceLeaseManager, AutomationJournal, AutomationArtifactRegistry) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("durable-campaign-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (AutomationDeviceLeaseManager(), try AutomationJournal(url: root.appendingPathComponent("journal.json")),
            try AutomationArtifactRegistry(root: root.appendingPathComponent("artifacts")))
    }

    func testHostStepsKeepFullApprovalDigestAndNeverDispatchTheStorageReader() throws {
        let (plan, approval) = try fixture()
        let host = try AutomationXCUITestPlan.assemble(plan: plan, approval: approval, attemptID: "attempt", leaseGeneration: 1)
        XCTAssertEqual(host.planDigest, try AutomationFrozenCase.planDigest(plan))
        XCTAssertEqual(host.steps.filter { $0.kind == .invokeIntent }.count, 1)
        XCTAssertFalse(host.steps.contains { $0.segmentID == "read" })
        var changed = plan; changed.cleanup = [AutomationSegment(id: "cleanup", kind: .systemIntent, phase: .cleanup, operation: "Mutate")]
        XCTAssertThrowsError(try AutomationXCUITestPlan.durableObservationSuffix(plan: changed))
        changed = plan
        var late = plan.execution; late.id = "late-host-read"; late.phase = .observe; late.kind = .systemQuery
        changed.observations.append(late)
        XCTAssertThrowsError(try AutomationXCUITestPlan.durableObservationSuffix(plan: changed))
        changed = plan; changed.observations[0].kind = .systemQuery
        XCTAssertThrowsError(try AutomationXCUITestPlan.durableObservationSuffix(plan: changed))
    }

    func testCompletedSubjectIsNotRepeatedAndReaderUsesNewSystemLeaseUnderSameCampaign() async throws {
        let (plan, approval) = try fixture(), (leases, journal, artifacts) = try resources()
        try await leases.reserveCampaign(runID: approval.runID, target: plan.target)
        let hostLease = try await leases.acquire(runID: approval.runID, target: plan.target, control: .ui)
        let prior = [hostReceipt(plan, generation: hostLease.generation)]
        try await leases.release(hostLease, commandsDrained: true, ownedRunnerTerminated: true)
        let driver = Reader(leases: leases)
        let budget = try AutomationCampaignBudget(limits: .init())
        let suffix = try await AutomationXCUITestDurableObservations.execute(plan: plan, approval: approval,
            capabilities: .init(), attemptID: "attempt", priorReceipts: prior,
            deadline: .now.advanced(by: .seconds(10)), leases: leases, artifacts: artifacts, journal: journal,
            campaignBudget: budget, driver: driver)
        XCTAssertNil(suffix.termination); XCTAssertTrue(suffix.resourcesReleased)
        let events = await driver.events, controls = await driver.controls, generations = await driver.generations
        XCTAssertEqual(events, ["acquire:read", "execute:read", "release:read"])
        XCTAssertEqual(controls, [.system]); XCTAssertTrue(generations.allSatisfy { $0 > hostLease.generation })
        XCTAssertEqual((prior + suffix.receipts).filter { $0.segmentID == plan.execution.id }.count, 1)
        let result = AutomationAssessment.assess(plan: plan, attemptID: "attempt", subjectDispatched: true,
            subjectCompleted: true, observations: suffix.receipts.flatMap(\.observations), receipts: prior + suffix.receipts, runID: "run")
        XCTAssertEqual(result.summary, .passed)
        try AutomationRecordedEvidence.validate(report: .init(attemptID: "attempt", result: result,
            receipts: prior + suffix.receipts, resourcesReleased: true), plan: plan, expectedRunID: "run")
        let usage = await budget.snapshot()
        XCTAssertEqual(usage.reservedObserverOperations, 1)
        let absent = try await leases.campaignAbsent(target: plan.target)
        XCTAssertFalse(absent, "Independent observations cannot release campaign ownership")
        do { _ = try await leases.acquire(runID: "different", target: plan.target, control: .system); XCTFail("Campaign released early") }
        catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
        try await leases.releaseCampaign(runID: approval.runID, target: plan.target)
    }

    func testFailedOrForeignHostFactsNeverEnterTheReader() async throws {
        let (plan, approval) = try fixture(), (leases, journal, artifacts) = try resources()
        let driver = Reader(leases: leases)
        var failed = hostReceipt(plan); failed.completed = false
        var wrongIdentity = hostReceipt(plan); wrongIdentity.app.bundleID = "foreign.App"
        var wrongAttempt = hostReceipt(plan); wrongAttempt.scope.attemptId = "another-attempt"
        for prior in [[], [failed], [wrongIdentity], [wrongAttempt], [hostReceipt(plan), hostReceipt(plan)]] {
            do {
                _ = try await AutomationXCUITestDurableObservations.execute(plan: plan, approval: approval,
                    capabilities: .init(), attemptID: "attempt", priorReceipts: prior,
                    deadline: .now.advanced(by: .seconds(10)), leases: leases, artifacts: artifacts,
                    journal: journal, campaignBudget: nil, driver: driver)
                XCTFail("Incomplete or unrelated host facts admitted")
            } catch { }
        }
        let events = await driver.events
        XCTAssertTrue(events.isEmpty)
    }

    func testReaderFailureRetainsCompletedSubjectFactsAndReleasesOnlyItsSystemLease() async throws {
        let (plan, approval) = try fixture(), (leases, journal, artifacts) = try resources()
        try await leases.reserveCampaign(runID: approval.runID, target: plan.target)
        let prior = [hostReceipt(plan)], driver = Reader(leases: leases, fail: true)
        let suffix = try await AutomationXCUITestDurableObservations.execute(plan: plan, approval: approval,
            capabilities: .init(), attemptID: "attempt", priorReceipts: prior,
            deadline: .now.advanced(by: .seconds(10)), leases: leases, artifacts: artifacts, journal: journal,
            campaignBudget: nil, driver: driver)
        XCTAssertEqual(suffix.termination, .unresolved); XCTAssertTrue(suffix.resourcesReleased)
        XCTAssertTrue(suffix.receipts.isEmpty); XCTAssertTrue(prior[0].completed)
        let lease = try await leases.acquire(runID: approval.runID, target: plan.target, control: .system)
        try await leases.release(lease, commandsDrained: true, ownedRunnerTerminated: true)
        let absent = try await leases.campaignAbsent(target: plan.target)
        XCTAssertFalse(absent)
        try await leases.releaseCampaign(runID: approval.runID, target: plan.target)
    }

    func testExpiredAttemptCannotRestartItsDeadlineForStorage() async throws {
        let (plan, approval) = try fixture(), (leases, journal, artifacts) = try resources()
        let driver = Reader(leases: leases)
        let suffix = try await AutomationXCUITestDurableObservations.execute(plan: plan, approval: approval,
            capabilities: .init(), attemptID: "attempt", priorReceipts: [hostReceipt(plan)],
            deadline: .now.advanced(by: .seconds(-1)), leases: leases, artifacts: artifacts, journal: journal,
            campaignBudget: nil, driver: driver)
        XCTAssertEqual(suffix.termination, .timedOut)
        let events = await driver.events
        XCTAssertTrue(events.isEmpty)
    }

    func testActiveHostLeaseCannotBeOverlappedByAnIndependentRead() async throws {
        let (plan, approval) = try fixture(), (leases, journal, artifacts) = try resources()
        let hostLease = try await leases.acquire(runID: approval.runID, target: plan.target, control: .ui)
        let driver = Reader(leases: leases)
        let suffix = try await AutomationXCUITestDurableObservations.execute(plan: plan, approval: approval,
            capabilities: .init(), attemptID: "attempt", priorReceipts: [hostReceipt(plan, generation: hostLease.generation)],
            deadline: .now.advanced(by: .seconds(10)), leases: leases, artifacts: artifacts, journal: journal,
            campaignBudget: nil, driver: driver)
        XCTAssertFalse(suffix.resourcesReleased); XCTAssertEqual(suffix.termination, .unresolved)
        let current = await leases.isCurrent(hostLease), events = await driver.events
        XCTAssertTrue(current); XCTAssertTrue(events.isEmpty)
        try await leases.release(hostLease, commandsDrained: true, ownedRunnerTerminated: true)
        try await leases.releaseCampaign(runID: approval.runID, target: plan.target)
    }

    func testUndrainedReaderKeepsItsLeaseAndCampaignUnresolved() async throws {
        let (plan, approval) = try fixture(), (leases, journal, artifacts) = try resources()
        try await leases.reserveCampaign(runID: approval.runID, target: plan.target)
        let driver = Reader(leases: leases, releaseDrained: false)
        let suffix = try await AutomationXCUITestDurableObservations.execute(plan: plan, approval: approval,
            capabilities: .init(), attemptID: "attempt", priorReceipts: [hostReceipt(plan)],
            deadline: .now.advanced(by: .seconds(10)), leases: leases, artifacts: artifacts, journal: journal,
            campaignBudget: nil, driver: driver)
        XCTAssertFalse(suffix.resourcesReleased); XCTAssertEqual(suffix.termination, .unresolved)
        let retainedLease = await driver.lastLease
        let lease = try XCTUnwrap(retainedLease)
        let current = await leases.isCurrent(lease), absent = try await leases.campaignAbsent(target: plan.target)
        XCTAssertTrue(current); XCTAssertFalse(absent)
        do { _ = try await leases.acquire(runID: approval.runID, target: plan.target, control: .system); XCTFail("Undrained reader released") }
        catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
        // The injected driver owns no process. End this synthetic test's retained ownership.
        try await leases.release(lease, commandsDrained: true, ownedRunnerTerminated: true)
        try await leases.releaseCampaign(runID: approval.runID, target: plan.target)
    }

    func testCancelledSuffixDoesNotEnterReaderOrReleaseCampaignOwnership() async throws {
        let (plan, approval) = try fixture(), (leases, journal, artifacts) = try resources()
        try await leases.reserveCampaign(runID: approval.runID, target: plan.target)
        let driver = Reader(leases: leases), gate = CancellationGate(), prior = [hostReceipt(plan)]
        let task = Task {
            await gate.wait()
            return try await AutomationXCUITestDurableObservations.execute(plan: plan, approval: approval,
                capabilities: .init(), attemptID: "attempt", priorReceipts: prior,
                deadline: .now.advanced(by: .seconds(10)), leases: leases, artifacts: artifacts, journal: journal,
                campaignBudget: nil, driver: driver)
        }
        task.cancel(); await gate.open()
        let suffix = try await task.value
        XCTAssertEqual(suffix.termination, .cancelled); XCTAssertTrue(suffix.resourcesReleased)
        let events = await driver.events, absent = try await leases.campaignAbsent(target: plan.target)
        XCTAssertTrue(events.isEmpty); XCTAssertFalse(absent)
        try await leases.releaseCampaign(runID: approval.runID, target: plan.target)
    }

    private actor CancellationGate {
        var isOpen = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            isOpen = true; continuation?.resume(); continuation = nil
        }
    }

    private actor Reader: AutomationResolvedRouteDriver {
        let leases: AutomationDeviceLeaseManager
        let fail: Bool
        let releaseDrained: Bool
        var events: [String] = []
        var controls: [AutomationDeviceLeaseManager.Lease.Control] = []
        var generations: [Int] = []
        var lastLease: AutomationDeviceLeaseManager.Lease?
        init(leases: AutomationDeviceLeaseManager, fail: Bool = false, releaseDrained: Bool = true) {
            self.leases = leases; self.fail = fail; self.releaseDrained = releaseDrained
        }
        func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope,
                     lease: AutomationDeviceLeaseManager.Lease) async throws {
            XCTFail("Expected resolved independent observation authority")
            throw AutomationContractError.invalidIdentity
        }
        func acquireResolved(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope,
                             lease: AutomationDeviceLeaseManager.Lease, authority: AutomationSegmentResolutionAuthority) async throws {
            guard try authority.matches(plan: plan, segment: segment, scope: scope), await leases.isCurrent(lease),
                  lease.control == .system else { throw AutomationContractError.unknownLease }
            events.append("acquire:" + segment.id); controls.append(lease.control); generations.append(lease.generation)
            lastLease = lease
        }
        func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope,
                     lease: AutomationDeviceLeaseManager.Lease) async throws -> AutomationSegmentReceipt {
            events.append("execute:" + segment.id)
            if fail { throw AutomationContractError.missingEvidence("Synthetic storage failure") }
            let reader = try XCTUnwrap(segment.durableStateReader)
            let value: AutomationValue = .array([.object(["entity": .entity(typeID: reader.declaration.entityTypeID, value: "selected"),
                "properties": .object(["title": .text("Send invoice"), "owner": .text("Work"), "completed": .bool(true), "control": .text("correct")])])])
            let outputs = ["records": value]
            var observation = AutomationObservation(id: segment.id, app: plan.app, target: plan.target,
                environmentID: plan.environmentID, attemptID: scope.attemptId, stepID: segment.id, route: .storageRead,
                proof: .persistedState, value: value)
            observation.artifact = "synthetic-reader-artifact"
            var receipt = AutomationSegmentReceipt(scope: scope, app: plan.app, target: plan.target,
                segmentID: segment.id, route: .storageRead, dispatched: true, completed: true, observations: [observation],
                artifact: observation.artifact, verifiedOutputs: outputs, environmentID: plan.environmentID)
            receipt.durableStateRead = .init(scope: scope, planDigest: try AutomationFrozenCase.planDigest(plan),
                recipeDigest: try reader.digest(), documentDigest: String(repeating: "f", count: 64),
                outputsDigest: try AutomationDurableStateReadReceipt.outputsDigest(outputs))
            return receipt
        }
        func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async -> AutomationReleaseProof {
            events.append("release:" + scope.segmentId)
            return .init(commandsDrained: releaseDrained, runnerTerminated: releaseDrained)
        }
    }
}
#endif
