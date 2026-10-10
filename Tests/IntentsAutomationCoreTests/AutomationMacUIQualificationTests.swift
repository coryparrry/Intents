#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationMacUIQualificationTests: XCTestCase, @unchecked Sendable {
    enum Mode: Sendable { case normal, rawFill, changedFill, wrongScroll, extraOutput, foreignReadback, badRelease, rawPress, suspended, factorySuspended, subjectSuspended, badScalar, foreignInstance }
    actor Trace {
        var calls: [String] = []
        var factoryPending: CheckedContinuation<Void, Never>?
        func suspendFactory() async { calls.append("factory-pending"); await withCheckedContinuation { factoryPending = $0 } }
        func finishFactory() { factoryPending?.resume(); factoryPending = nil }
        func record(_ value: String) { calls.append(value) }
        func values() -> [String] { calls }
        func wait(_ value: String) async throws {
            let end = ContinuousClock.now.advanced(by: .seconds(5))
            while !calls.contains(value), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
            guard calls.contains(value) else { throw AutomationRPCError.timedOut }
        }
    }
    struct Subject: AutomationSubjectVerifier {
        let selected: AutomationInstalledMacUIApplication
        var trace: Trace? = nil
        func verify(app: AppIdentity, target: TargetIdentity) async throws {
            guard selected.app == app, selected.target == target else { throw AutomationContractError.invalidIdentity }
            try selected.verifySelectedProduct()
            if let trace { await trace.suspendFactory() }
        }
    }
    actor Session: AutomationMacProgramSession {
        let context: AutomationMacUIRouteDriver.SessionContext, trace: Trace, mode: Mode
        var closed = false
        var pending: CheckedContinuation<AutomationJSON, any Error>?
        init(_ context: AutomationMacUIRouteDriver.SessionContext, trace: Trace, mode: Mode) {
            self.context = context; self.trace = trace; self.mode = mode
        }
        func encoded<T: Encodable>(_ value: T) throws -> AutomationJSON {
            try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(value))
        }
        func request(_ kind: String) throws -> AutomationJSON {
            .object(["scope": try encoded(context.scope), "selection": .object(["bundleId": .string(context.app.bundleID),
                "canonicalBundlePath": .string(context.app.canonicalBundlePath!)]), "action": .object(["kind": .string(kind)])])
        }
        func open(programMode: Bool) async throws -> AutomationJSON {
            XCTAssertTrue(programMode); await trace.record("open")
            var policy = try encoded(context.scope).object!
            policy["effect"] = .string("activate")
            policy["target"] = .object(["id": .string(context.target.id), "kind": .string("nativeMac"), "platform": .string("macos"),
                "bundleId": .string(context.app.bundleID), "bundlePath": .string(context.app.canonicalBundlePath!),
                "loginSession": .string(context.target.loginSession!)])
            let allowed = try await context.review("policy.reviewAction", .object(policy))
            guard allowed.object?["allowed"] == .bool(true) else { throw AutomationContractError.invalidIdentity }
            try await context.authorize(request("acquire")); await trace.record("activation")
            return .object(["bundleId": .string(mode == .foreignInstance ? "foreign.App" : context.app.bundleID),
                "canonicalBundlePath": .string(context.app.canonicalBundlePath!), "pid": .number(123), "processStartIdentity": .string("100:0")])
        }
        func runProgram(_ program: AutomationUIProgram, phase: AutomationSegment.Phase, operationID: String) async throws -> AutomationJSON {
            await trace.record("running")
            if mode == .suspended { return try await withCheckedThrowingContinuation { pending = $0 } }
            if mode == .rawFill { try await context.authorize(request("ordinaryFill")); XCTFail("Unapproved fill accepted") }
            if mode == .rawPress { try await context.authorize(request("press")); XCTFail("Unapproved press accepted") }
            var outputs: [String: AutomationJSON] = [:]
            for operation in program.operations {
                if operation.kind == .tap {
                    var policy = try encoded(context.scope).object!
                    policy["action"] = .object(["kind": .string("tap")])
                    guard try await context.review("policy.reviewAction", .object(policy)).object?["allowed"] == .bool(true) else {
                        throw AutomationContractError.invalidIdentity
                    }
                    try await context.authorize(request("press")); await trace.record("press")
                    do { try await context.authorize(request("press")); XCTFail("Grant reused") } catch {}
                }
                if operation.kind == .fillBinding || operation.kind == .scroll {
                    var policy = try encoded(context.scope).object!
                    let value = operation.binding.flatMap { program.bindings[$0] }
                    policy["action"] = operation.kind == .fillBinding ? .object(["kind": .string("fill"), "value": .string(value!), "sensitive": .bool(false)]) : .object(["kind": .string("swipe"), "direction": .string(operation.direction!)])
                    guard try await context.review("policy.reviewAction", .object(policy)).object?["allowed"] == .bool(true) else { throw AutomationContractError.invalidIdentity }
                    // A second policy grant cannot overwrite a pending native permit.
                    let duplicatePolicy = try await context.review("policy.reviewAction", .object(policy))
                    XCTAssertEqual(duplicatePolicy.object?["allowed"], .bool(false))
                    var native = try request(operation.kind == .fillBinding ? "ordinaryFill" : "scroll").object!
                    var action = native["action"]!.object!
                    if let value { action["value"] = .string(mode == .changedFill ? "é🙂" : value) }
                    else { action["direction"] = .string(mode == .wrongScroll ? "up" : operation.direction!) }
                    native["action"] = .object(action)
                    try await context.authorize(.object(native)); await trace.record(operation.kind == .fillBinding ? "fill" : "scroll")
                    do { try await context.authorize(.object(native)); XCTFail("Native input grant reused") } catch {}
                }
                if [.readProperty, .locate, .observeProperty].contains(operation.kind) {
                    try await context.authorize(request("snapshot")); await trace.record("capture")
                    outputs[operation.id] = .object(["schemaVersion": .number(1), "appBundleId": .string(mode == .foreignReadback ? "foreign.App" : context.app.bundleID),
                        "targetId": .string(context.target.id), "complete": .bool(true), "nodes": .array([
                            .object(["index": .number(1), "identifier": .string("status"), "label": .string("Ready"),
                                     "blocked": .bool(false), "hidden": .bool(false), "visible": .bool(true), "disabled": .bool(false), "secure": .bool(false)])])])
                }
            }
            if mode == .badScalar { for key in outputs.keys { outputs[key] = .object([:]) } }
            if mode == .extraOutput { outputs["foreign"] = .string("unexpected") }
            return .object(["schemaVersion": .number(1), "scope": try encoded(context.scope), "operationId": .string(operationID),
                            "complete": .bool(true), "outputs": .object(outputs)])
        }
        func close() async -> AutomationReleaseProof {
            if !closed {
                closed = true; await trace.record(Task.isCancelled ? "cancelled-close" : "close")
                pending?.resume(throwing: CancellationError()); pending = nil
            }
            return .init(commandsDrained: true, runnerTerminated: mode != .badRelease)
        }
    }
    struct Harness {
        let root: URL, bundle: URL, selected: AutomationInstalledMacUIApplication, runner: AutomationApplicationRunner, trace: Trace
    }
    func harness(mode: Mode = .normal, enabled: Bool = true, receipt: String = AutomationPrivateMacDaemonUnit.pinnedProgramReceiptSHA256) throws -> Harness {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("mac-compose-" + UUID().uuidString)
        let developer = root.appendingPathComponent("Developer"), bundle = root.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: developer, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try PropertyListSerialization.data(fromPropertyList: ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "example.MacUI", "CFBundleExecutable": "Fixture",
            "CFBundleSupportedPlatforms": ["MacOSX"]], format: .binary, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try AutomationPhysicalExecutableTests.binary(platform: 1).write(to: bundle.appendingPathComponent("Contents/MacOS/Fixture"))
        let selected = try AutomationInstalledMacUIApplication(bundleURL: bundle, target: .init(id: "host-macos-local", kind: .nativeMac, loginSession: "synthetic-login"))
        let trace = Trace()
        let dependencies = AutomationMacUIQualification.Dependencies(runtimeRoot: root, verifyRuntime: { _ in receipt }, driver: { context in
            try AutomationMacUIRouteDriver(state: context.state, approval: context.approval, leases: context.leases, artifacts: context.artifacts,
                subject: Subject(selected: selected, trace: mode == .subjectSuspended ? trace : nil), campaignBudget: context.campaignBudget, inputCapabilities: context.inputCapabilities, factory: { session in
                    await trace.record("factory"); if mode == .factorySuspended { await trace.suspendFactory() }; return Session(session, trace: trace, mode: mode)
                })
        })
        let runner: AutomationApplicationRunner
        if enabled {
            runner = try .init(supportRoot: root.appendingPathComponent("Support"), developerDirectory: developer,
                simulatorInventory: { _, _ in XCTFail("Mac must not inspect simulators"); throw AutomationContractError.invalidIdentity }, macQualification: dependencies)
        } else { runner = try .init(supportRoot: root.appendingPathComponent("Support"), developerDirectory: developer) }
        return .init(root: root, bundle: bundle, selected: selected, runner: runner, trace: trace)
    }
    func plan(_ h: Harness, observe: Bool = false) -> AutomationCase {
        var segment = AutomationSegment(id: "subject", kind: .ui, phase: .subject, operation: "inspect", effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
        segment.uiProgram = .init(operations: [.init(id: "tap", kind: .tap, locator: .init(.label, "Ready"))])
        var plan = AutomationCase(id: "mac-ui", app: h.selected.app, target: h.selected.target, environmentID: "test", execution: segment)
        plan.provenance["ui.privateMacReceiptSHA256"] = AutomationPrivateMacDaemonUnit.pinnedProgramReceiptSHA256
        if observe {
            var observation = AutomationSegment(id: "observer", kind: .ui, phase: .observe, operation: "inspect", effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
            observation.uiProgram = .init(operations: [.init(id: "status", kind: .observeProperty, locator: .init(.testId, "status"), property: "text")])
            plan.observations = [observation]
        }
        return plan
    }
    func run(_ h: Harness, plan: AutomationCase? = nil, attempt: String = "attempt", budget: AutomationCampaignBudget? = nil) async throws -> AutomationAttemptReport {
        let plan = plan ?? self.plan(h)
        let approval = RunApproval(runID: "run", app: plan.app, target: plan.target, environmentID: "test", effects: (plan.setup + [plan.execution] + plan.observations + plan.cleanup).reduce(into: Set<AutomationEffect>()) { $0.formUnion($1.effects) }, maximumActions: 10, disposable: true)
        return try await h.runner.run(subject: .installedMacUI(h.selected), plan: plan, approval: approval, capabilities: .init(), attemptID: attempt,
            allowBootAndInstall: false, campaignBudget: budget)
    }
    func testNativeCampaignUsesApprovalTypedReadbackArtifactsJournalAndReleasedLeases() async throws {
        let h = try harness(), report = try await run(h, plan: plan(h, observe: true))
        XCTAssertTrue(report.resourcesReleased); XCTAssertTrue(report.result.subjectCompleted); XCTAssertEqual(report.receipts.count, 2)
        XCTAssertEqual(report.receipts.last?.verifiedOutputs?["status"], .text("Ready")); XCTAssertEqual(report.receipts.last?.observations.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.root.appendingPathComponent("Support/attempt/report.json").path))
        let calls = await h.trace.values(); XCTAssertEqual(calls.filter { $0 == "factory" }.count, 2); XCTAssertEqual(calls.filter { $0 == "press" }.count, 1)
        XCTAssertEqual(calls.filter { $0 == "close" }.count, 2)
    }
    func testPublicRunnerFencePrecedesAttemptAndFactory() async throws {
        let h = try harness(enabled: false)
        do { _ = try await run(h); XCTFail("Customer route enabled") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.root.appendingPathComponent("Support/attempt").path)); let calls = await h.trace.values(); XCTAssertEqual(calls, [])
    }
    func testRuntimeReceiptAndFrozenPlanMismatchPrecedeOwnership() async throws {
        for digest in [AutomationPrivateMacDaemonUnit.pinnedReceiptSHA256, String(repeating: "a", count: 64)] {
            let h = try harness(receipt: digest)
            do { _ = try await run(h); XCTFail("Wrong runtime accepted") } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: h.root.appendingPathComponent("Support/attempt").path))
        }
        let h = try harness(); var p = plan(h); p.provenance.removeValue(forKey: "ui.privateMacReceiptSHA256")
        do { _ = try await run(h, plan: p); XCTFail("Unbound runtime accepted") } catch {}
    }
    func inputPlan(_ h: Harness) -> AutomationCase {
        var value = plan(h); value.provenance["ui.privateMacReceiptSHA256"] = AutomationPrivateMacDaemonUnit.pinnedFillProgramReceiptSHA256
        value.execution.effects.insert(.fixtureWrite)
        value.execution.uiProgram = .init(operations: [.init(id: "fill", kind: .fillBinding, locator: .init(.role, "textbox"), binding: "text"),
            .init(id: "scroll", kind: .scroll, direction: "down")], bindings: ["text": "e\u{0301}🙂"])
        return value
    }
    func testPinnedFillRuntimeUsesExactOneShotNativeFillAndScrollGrants() async throws {
        let h = try harness(receipt: AutomationPrivateMacDaemonUnit.pinnedFillProgramReceiptSHA256)
        let report = try await run(h, plan: inputPlan(h))
        XCTAssertTrue(report.resourcesReleased); XCTAssertTrue(report.result.subjectCompleted)
        let calls = await h.trace.values(); XCTAssertEqual(calls.filter { $0 == "fill" }.count, 1); XCTAssertEqual(calls.filter { $0 == "scroll" }.count, 1)
    }
    func testUnapprovedChangedFillAndWrongScrollCannotConsumeNativePermits() async throws {
        let modes: [Mode] = [.rawFill, .changedFill, .wrongScroll]
        for mode in modes {
            let h = try harness(mode: mode, receipt: AutomationPrivateMacDaemonUnit.pinnedFillProgramReceiptSHA256)
            let report = try await run(h, plan: inputPlan(h))
            XCTAssertTrue(report.resourcesReleased); XCTAssertFalse(report.result.subjectCompleted)
            let calls = await h.trace.values()
            XCTAssertFalse(calls.contains("scroll")); if mode != .wrongScroll { XCTAssertFalse(calls.contains("fill")) }
        }
    }
    func testInvalidFillLiteralPreventsFactoryAndActivation() async throws {
        let h = try harness(receipt: AutomationPrivateMacDaemonUnit.pinnedFillProgramReceiptSHA256); var value = inputPlan(h)
        value.execution.uiProgram?.bindings["text"] = "invalid\0"
        do { _ = try await run(h, plan: value); XCTFail("Invalid literal accepted") } catch {}
        let calls = await h.trace.values(); XCTAssertEqual(calls, [])
    }
    func testUnsupportedWholeProgramPreflightPreventsEvenActivation() async throws {
        let h = try harness(); var p = plan(h)
        p.execution.uiProgram?.operations.append(.init(id: "scroll", kind: .scroll, direction: "down"))
        do { _ = try await run(h, plan: p); XCTFail("Unsupported program accepted") } catch {}
        let calls = await h.trace.values(); XCTAssertEqual(calls, [])
    }
    func testChangedProductAndWrongTargetCannotDispatch() async throws {
        let h = try harness(); try Data("changed".utf8).write(to: h.bundle.appendingPathComponent("Contents/resource.txt"))
        do { _ = try await run(h); XCTFail("Changed product accepted") } catch {}
        let calls = await h.trace.values(); XCTAssertEqual(calls, [])
        XCTAssertThrowsError(try AutomationInstalledMacUIApplication(bundleURL: h.bundle, target: .init(id: "other", kind: .nativeMac, loginSession: "login")))
    }
    func testUnexpectedOutputAndForeignReadbackCannotBecomePositiveEvidence() async throws {
        for mode in [Mode.extraOutput, .foreignReadback] {
            let h = try harness(mode: mode), report = try await run(h, plan: plan(h, observe: true))
            XCTAssertFalse(report.executionSucceeded); XCTAssertTrue(report.resourcesReleased)
            XCTAssertFalse(report.receipts.contains { !$0.observations.isEmpty })
        }
    }
    func testInvalidScalarAndLocatorOutputsCannotCompleteProgram() async throws {
        for kind in [AutomationUIProgram.Operation.Kind.readProperty, .locate] {
            let h = try harness(mode: .badScalar); var p = plan(h)
            p.execution.uiProgram = .init(operations: [.init(id: "read", kind: kind, locator: .init(.label, "Ready"), property: kind == .readProperty ? "text" : nil)])
            let report = try await run(h, plan: p)
            XCTAssertFalse(report.executionSucceeded); XCTAssertFalse(report.result.subjectCompleted); XCTAssertTrue(report.resourcesReleased)
        }
    }
    func testForeignAcquisitionCannotRunProgram() async throws {
        let h = try harness(mode: .foreignInstance), report = try await run(h)
        XCTAssertFalse(report.result.subjectDispatched); XCTAssertTrue(report.resourcesReleased)
        let calls = await h.trace.values(); XCTAssertFalse(calls.contains("running"))
    }
    func testRawNativePressWithoutPolicyGrantIsDenied() async throws {
        let h = try harness(mode: .rawPress), report = try await run(h)
        XCTAssertFalse(report.executionSucceeded); XCTAssertTrue(report.resourcesReleased)
        let calls = await h.trace.values(); XCTAssertFalse(calls.contains("press"))
    }
    func testUncertainReleaseRetainsCampaignAndBlocksNewFactory() async throws {
        let h = try harness(mode: .badRelease), report = try await run(h)
        XCTAssertFalse(report.resourcesReleased); XCTAssertFalse(report.executionSucceeded)
        _ = try await run(h, attempt: "second")
        let calls = await h.trace.values(); XCTAssertEqual(calls.filter { $0 == "factory" }.count, 1)
    }
    func testCancellationDrainsSuspendedProgramOutsideCancelledTask() async throws {
        let h = try harness(mode: .suspended), task = Task { try await run(h) }
        try await h.trace.wait("running"); task.cancel()
        let report = try await task.value
        XCTAssertTrue(report.resourcesReleased); XCTAssertFalse(report.executionSucceeded)
        let calls = await h.trace.values(); XCTAssertTrue(calls.contains("close")); XCTAssertFalse(calls.contains("cancelled-close"))
    }
    func testCancellationDuringFactoryRetainsAndJoinsExactLateSessionWithoutOpening() async throws {
        let h = try harness(mode: .factorySuspended), task = Task { try await run(h) }
        try await h.trace.wait("factory-pending"); task.cancel()
        try await Task.sleep(for: .milliseconds(30))
        await h.trace.finishFactory()
        let report = try await task.value
        XCTAssertTrue(report.resourcesReleased); XCTAssertFalse(report.result.subjectDispatched)
        let calls = await h.trace.values(); XCTAssertFalse(calls.contains("open")); XCTAssertEqual(calls.filter { $0 == "close" }.count, 1)
        XCTAssertFalse(calls.contains("cancelled-close"))
        let leases = try AutomationDeviceLeaseManager(storeURL: h.root.appendingPathComponent("Support/target-leases.json"))
        let records = try await leases.recoveryRecords(); XCTAssertTrue(records.isEmpty)
    }
    func testCancellationBeforeControlCreationJoinsAcquisitionWithoutStrandingLease() async throws {
        let h = try harness(mode: .subjectSuspended), task = Task { try await run(h) }
        try await h.trace.wait("factory-pending"); task.cancel()
        try await Task.sleep(for: .milliseconds(30)); await h.trace.finishFactory()
        let report = try await task.value
        XCTAssertTrue(report.resourcesReleased); XCTAssertFalse(report.result.subjectDispatched)
        let calls = await h.trace.values(); XCTAssertFalse(calls.contains("factory")); XCTAssertFalse(calls.contains("open"))
        let leases = try AutomationDeviceLeaseManager(storeURL: h.root.appendingPathComponent("Support/target-leases.json"))
        let records = try await leases.recoveryRecords(); XCTAssertTrue(records.isEmpty)
    }
    func testCampaignDeadlineStopsPendingProgramBeforePlanDeadlineAndDrains() async throws {
        let h = try harness(mode: .suspended); var limits = AutomationCampaignLimits(); limits.wallClockSeconds = 1
        let budget = try AutomationCampaignBudget(limits: limits), start = ContinuousClock.now
        let report = try await run(h, budget: budget)
        XCTAssertFalse(report.executionSucceeded); XCTAssertTrue(report.resourcesReleased)
        XCTAssertLessThan(start.duration(to: .now), .seconds(5))
    }
}
#endif
