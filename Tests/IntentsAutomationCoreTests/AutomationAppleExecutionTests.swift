#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

extension AutomationAppleRouteDriverTests {
    actor CommandFixture {
        let harness: Harness
        var calls: [String] = [], stops = 0
        init(_ harness: Harness) { self.harness = harness }
        func run(_ arguments: [String], root: URL, timeout: Duration) throws -> AutomationOwnedCommand.Result {
            calls.append(arguments[0])
            if arguments[0] == "xcresulttool" {
                let index = try XCTUnwrap(arguments.firstIndex(of: "--output-path"))
                let output = URL(fileURLWithPath: arguments[index + 1]); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let h = harness
                let receipt: [String: Any] = ["schemaVersion": 2,
                    "runner": ["pid": Int32.max, "startIdentity": "100:0", "executablePath": h.host.hostBundlePath + "/OwnedHost-Runner"],
                    "runID": h.scope.runId, "attemptID": h.scope.attemptId, "segmentID": h.scope.segmentId, "leaseGeneration": h.scope.leaseGeneration,
                    "bundleID": h.host.app.bundleID, "productDigest": h.host.app.productDigest!, "productDigestVersion": 1, "complete": true,
                    "operations": [["operationID": "probe", "dispatched": true, "value": ["kind": "noValue"]]]]
                try JSONSerialization.data(withJSONObject: receipt).write(to: output.appendingPathComponent("receipt.json"))
            }
            return .init(exitStatus: 0, stdout: Data(), stderr: Data(), logsTruncated: false)
        }
        func stop() -> Bool { stops += 1; return true }
        nonisolated var adapter: AutomationAppleRouteDriver.Commands {
            .init(run: { try await self.run($0, root: $1, timeout: $2) }, stop: { await self.stop() })
        }
    }
    actor SuspendedSubject: AutomationSubjectVerifier {
        let expected: Subject, suspendAt: Int
        var calls = 0, pending: CheckedContinuation<Void, Never>?
        init(_ expected: Subject, suspendAt: Int) { self.expected = expected; self.suspendAt = suspendAt }
        func verify(app: AppIdentity, target: TargetIdentity) async throws {
            try await expected.verify(app: app, target: target); calls += 1
            if calls == suspendAt { await withCheckedContinuation { pending = $0 } }
        }
        func resume() { pending?.resume(); pending = nil }
        func waitForSuspension() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while pending == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            guard pending != nil else { throw AutomationRPCError.timedOut }
        }
    }
    func testSimulatedExecutionCompletesOnceAndRejectsReplay() async throws {
        let h = try await fixture(), commands = CommandFixture(h), driver = try driver(h, commands: commands.adapter)
        try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease)
        let receipt = try await driver.execute(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease)
        XCTAssertTrue(receipt.completed); XCTAssertEqual(receipt.verifiedOutputs?["probe"], .omission)
        do { _ = try await driver.execute(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease); XCTFail("Replayed intent dispatched") } catch {}
        let calls = await commands.calls; XCTAssertEqual(calls, ["xcodebuild", "xcresulttool"])
        let proof = await driver.release(scope: h.scope, lease: h.lease); XCTAssertTrue(proof.runnerTerminated)
    }
    func testSameRunUnknownAttemptSegmentOrLeaseCannotRevokeActiveWork() async throws {
        let h = try await fixture(), commands = CommandFixture(h), driver = try driver(h, commands: commands.adapter)
        try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease)
        var attempt = h.scope; attempt.attemptId = "foreign"
        var segment = h.scope; segment.segmentId = "foreign"
        var lease = h.lease; lease.control = .ui
        for (scope, selectedLease) in [(attempt, h.lease), (segment, h.lease), (h.scope, lease)] {
            let proof = await driver.release(scope: scope, lease: selectedLease); XCTAssertFalse(proof.commandsDrained); XCTAssertFalse(proof.runnerTerminated)
        }
        let receipt = try await driver.execute(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease); XCTAssertTrue(receipt.completed)
        let proof = await driver.release(scope: h.scope, lease: h.lease); XCTAssertTrue(proof.runnerTerminated)
    }
    func testCompetingExecutionsConsumeAuthorityBeforeSuspending() async throws {
        let h = try await fixture(), commands = CommandFixture(h)
        let subject = SuspendedSubject(Subject(app: h.host.app, target: h.host.target), suspendAt: 2)
        let driver = try driver(h, subject: subject, commands: commands.adapter)
        try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease)
        let first = Task { try await driver.execute(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease) }
        try await subject.waitForSuspension()
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    do { _ = try await driver.execute(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease); return false }
                    catch { return error as? AutomationContractError == .unknownLease }
                }
            }
            for await rejected in group { XCTAssertTrue(rejected) }
        }
        await subject.resume(); let receipt = try await first.value; XCTAssertTrue(receipt.completed)
        do { _ = try await driver.execute(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease); XCTFail("Consumed authority replayed") } catch {}
        let calls = await commands.calls; XCTAssertEqual(calls, ["xcodebuild", "xcresulttool"])
    }
    func testDetachedCanonicallyEquivalentParameterCannotChangeApprovedPayload() async throws {
        let h = try await fixture(); var plan = h.plan, approval = h.approval
        plan.execution.hostProgram?.operations[0].parameters = ["name": .text("e\u{301}")]
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        var changed = plan.execution; changed.hostProgram?.operations[0].parameters = ["name": .text("\u{e9}")]
        XCTAssertEqual(plan.execution, changed)
        let driver = try driver(h, approval: approval)
        do { try await driver.acquire(plan: plan, segment: changed, scope: h.scope, lease: h.lease); XCTFail("Different code units admitted") } catch {}
        let calls = await h.release.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testFrozenLaunchFileMutationCannotReachAnyCommand() async throws {
        let h = try await fixture(), commands = CommandFixture(h), driver = try driver(h, commands: commands.adapter)
        try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease)
        try Data("changed frozen launch input".utf8).write(to: h.root.appendingPathComponent("driver/system-\(h.lease.generation)/host.xctestrun"))
        do { _ = try await driver.execute(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease); XCTFail("Modified launch file dispatched") } catch {}
        let calls = await commands.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testFailedIndependentPreparationNeverReportsAnUnprovedRelease() async throws {
        let h = try await fixture(), driver = try driver(h); await h.release.failPreparation(.targetBusy)
        do { try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease); XCTFail("Busy host admitted") } catch {}
        let proof = await driver.release(scope: h.scope, lease: h.lease); XCTAssertTrue(proof.commandsDrained); XCTAssertFalse(proof.runnerTerminated)
        let calls = await h.release.calls; XCTAssertEqual(calls, ["prepare:example.Host.xctrunner", "release:example.Host.xctrunner"])
    }
    actor FailingSecondSubject: AutomationSubjectVerifier {
        var calls = 0
        func verify(app: AppIdentity, target: TargetIdentity) throws {
            calls += 1
            if calls > 1 { throw AutomationContractError.invalidIdentity }
        }
    }
    func testReacquisitionCannotEraseUnresolvedPreparationProof() async throws {
        let h = try await fixture(), subject = FailingSecondSubject(), driver = try driver(h, subject: subject)
        await h.release.failPreparation(.targetBusy)
        do { try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease); XCTFail("Busy host admitted") } catch {}
        do { try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease); XCTFail("Unresolved admission replaced") }
        catch let error as AutomationContractError { XCTAssertEqual(error, .unknownLease) }
        let subjectCalls = await subject.calls; XCTAssertEqual(subjectCalls, 1)
        let proof = await driver.release(scope: h.scope, lease: h.lease); XCTAssertTrue(proof.commandsDrained); XCTAssertFalse(proof.runnerTerminated)
        let calls = await h.release.calls; XCTAssertEqual(calls, ["prepare:example.Host.xctrunner", "release:example.Host.xctrunner"])
    }
    func testStopDuringFinalSubjectAwaitCannotPublishCompletedReceipt() async throws {
        let h = try await fixture(), commands = CommandFixture(h)
        let subject = SuspendedSubject(Subject(app: h.host.app, target: h.host.target), suspendAt: 3)
        let driver = try driver(h, subject: subject, commands: commands.adapter)
        try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease)
        let execution = Task { try await driver.execute(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease) }
        try await subject.waitForSuspension()
        let proof = await driver.release(scope: h.scope, lease: h.lease); XCTAssertFalse(proof.commandsDrained)
        await subject.resume()
        do { _ = try await execution.value; XCTFail("Stopped execution reported completion") } catch {}
        let final = await driver.release(scope: h.scope, lease: h.lease); XCTAssertTrue(final.commandsDrained); XCTAssertTrue(final.runnerTerminated)
    }
    func testUnknownPendingScopeCannotRevokeButExactStopIsHonoured() async throws {
        let h = try await fixture(), subject = SuspendedSubject(Subject(app: h.host.app, target: h.host.target), suspendAt: 1)
        let driver = try driver(h, subject: subject)
        let acquisition = Task { try await driver.acquire(plan: h.plan, segment: h.plan.execution, scope: h.scope, lease: h.lease) }
        try await subject.waitForSuspension(); var wrong = h.scope; wrong.attemptId = "foreign"
        let unknown = await driver.release(scope: wrong, lease: h.lease); XCTAssertFalse(unknown.commandsDrained)
        let stopped = await driver.release(scope: h.scope, lease: h.lease); XCTAssertFalse(stopped.commandsDrained)
        await subject.resume()
        do { try await acquisition.value; XCTFail("Stopped acquisition admitted control") } catch {}
        let proof = await driver.release(scope: h.scope, lease: h.lease); XCTAssertTrue(proof.commandsDrained); XCTAssertTrue(proof.runnerTerminated)
    }
}
#endif
