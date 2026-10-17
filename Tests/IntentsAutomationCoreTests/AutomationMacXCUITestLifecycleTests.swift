#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationMacXCUITestLifecycleTests: XCTestCase, @unchecked Sendable {
    private final class RegistrationEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func record(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
        func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
    }
    private func privateSubject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-registration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let subject = try AutomationPath.canonical(root).appendingPathComponent("Private.app")
        try FileManager.default.createDirectory(at: subject, withIntermediateDirectories: true)
        return subject
    }
    func testRegistrationUsesExactPrivateURLAndRevalidatesAroundCanonicalLookup() async throws {
        let subject = try privateSubject(), events = RegistrationEvents()
        try await AutomationMacPreparedRegistration.perform(subject: subject, bundleID: "example.Private",
            authorization: .init(deadline: .now.advanced(by: .seconds(30)), revalidate: {}),
            validate: { events.record("validate") },
            registerURL: { url in XCTAssertEqual(url, subject); events.record("register") },
            resolveURL: { bundleID in XCTAssertEqual(bundleID, "example.Private"); events.record("resolve"); return subject })
        XCTAssertEqual(events.snapshot(), ["validate", "register", "validate", "resolve", "validate"])
    }
    func testRegistrationErrorStopsBeforeLookupAndPreservesError() async throws {
        let subject = try privateSubject(), events = RegistrationEvents()
        let expected = AutomationContractError.missingEvidence("registration rejected")
        do {
            try await AutomationMacPreparedRegistration.perform(subject: subject, bundleID: "example.Private",
                authorization: .init(deadline: .now.advanced(by: .seconds(30)), revalidate: {}),
                validate: { events.record("validate") },
                registerURL: { _ in events.record("register"); throw expected },
                resolveURL: { _ in events.record("resolve"); return subject })
            XCTFail("Rejected registration admitted")
        } catch { XCTAssertEqual(error as? AutomationContractError, expected) }
        XCTAssertEqual(events.snapshot(), ["validate", "register"])
    }
    func testRegistrationRejectsMissingOrDifferentSameBundleCopy() async throws {
        let subject = try privateSubject(), other = try privateSubject()
        for resolved in [nil, other] {
            let events = RegistrationEvents()
            do {
                try await AutomationMacPreparedRegistration.perform(subject: subject, bundleID: "example.Private",
                    authorization: .init(deadline: .now.advanced(by: .seconds(30)), revalidate: {}),
                    validate: { events.record("validate") },
                    registerURL: { _ in events.record("register") },
                    resolveURL: { _ in events.record("resolve"); return resolved })
                XCTFail("Missing or different product admitted")
            } catch {
                guard case .missingEvidence = error as? AutomationContractError else { throw error }
            }
            XCTAssertEqual(events.snapshot(), ["validate", "register", "validate", "resolve"])
        }
    }
    func testRegistrationRevalidatesBeforeAnySideEffectAndAfterRegistration() async throws {
        let subject = try privateSubject()
        for changedAt in [0, 2] {
            let events = RegistrationEvents()
            do {
                try await AutomationMacPreparedRegistration.perform(subject: subject, bundleID: "example.Private",
                    authorization: .init(deadline: .now.advanced(by: .seconds(30)), revalidate: {}),
                    validate: {
                        if events.snapshot().count == changedAt { throw AutomationContractError.conflictingOperation }
                        events.record("validate")
                    }, registerURL: { _ in events.record("register") },
                    resolveURL: { _ in events.record("resolve"); return subject })
                XCTFail("Changed identity or login session admitted")
            } catch { XCTAssertEqual(error as? AutomationContractError, .conflictingOperation) }
            XCTAssertEqual(events.snapshot(), changedAt == 0 ? [] : ["validate", "register"])
        }
    }
    func testNoActivationNeverRegistersAndInvalidLaunchConsentIsRejected() async throws {
        let app = AppIdentity(logicalID: "fixture", bundleID: "example.Private", platform: "macos")
        let target = TargetIdentity(id: "host-macos-local", kind: .nativeMac)
        var subject = AutomationSegment(id: "subject", kind: .systemIntent, phase: .subject, operation: "Echo",
            effects: [.observe, .navigate], lifecycle: .noActivation)
        var plan = AutomationCase(id: "no-activation", app: app, target: target, environmentID: "fixture", execution: subject)
        var approval = RunApproval(runID: "run", app: app, target: target, environmentID: "fixture",
            effects: [.observe, .navigate], maximumActions: 20, disposable: true)
        let register = try AutomationMacPreparedRegistration.required(plan: plan, approval: approval, steps: [])
        XCTAssertFalse(register)
        let events = RegistrationEvents(), state = State([frame()])
        let lifecycle = AutomationMacXCUITestLifecycle(paths: paths, userID: 501,
            inspect: { await state.inspect() }, validate: {}, registration: { _ in events.record("register") })
        try await lifecycle.prepare(registerSubject: register)
        XCTAssertEqual(events.snapshot(), [])
        let launch = UIHostStep(id: "launch", segmentID: "subject", kind: .launch)
        XCTAssertThrowsError(try AutomationMacPreparedRegistration.required(plan: plan, approval: approval, steps: [launch]))
        subject.lifecycle = .persistedStateAcrossSegments; plan.execution = subject
        XCTAssertTrue(try AutomationMacPreparedRegistration.required(plan: plan, approval: approval, steps: [launch]))
        approval.effects = [.observe]
        XCTAssertThrowsError(try AutomationMacPreparedRegistration.required(plan: plan, approval: approval, steps: [launch]))
        approval.effects = [.observe, .navigate]; plan.execution.effects = [.observe]
        XCTAssertThrowsError(try AutomationMacPreparedRegistration.required(plan: plan, approval: approval, steps: [launch]))
    }
    private actor SuspendedInventory {
        private var entered = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var resume: CheckedContinuation<Void, Never>?
        func inspect(_ value: AutomationMacProcessInventory) async -> AutomationMacProcessInventory {
            entered = true; waiting.forEach { $0.resume() }; waiting = []
            await withCheckedContinuation { resume = $0 }
            return value
        }
        func waitForEntry() async {
            if entered { return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func finish() { resume?.resume(); resume = nil }
    }
    private actor RegistrationLease {
        private var revoked = false
        func revoke() { revoked = true }
        func validate() throws { if revoked { throw AutomationContractError.unknownLease } }
    }
    func testCancelledExpiredOrRevokedInventoryCannotRegisterAnApp() async throws {
        let subject = try privateSubject()
        for condition in ["cancelled", "expired", "revoked"] {
            let inventory = SuspendedInventory(), lease = RegistrationLease(), events = RegistrationEvents()
            let empty = frame()
            let lifecycle = AutomationMacXCUITestLifecycle(paths: paths, userID: 501,
                inspect: { await inventory.inspect(empty) }, validate: {}, registration: { authorization in
                    try await AutomationMacPreparedRegistration.perform(subject: subject, bundleID: "example.Private",
                        authorization: authorization, validate: {},
                        registerURL: { _ in events.record("register") }, resolveURL: { _ in subject })
                })
            let deadline = ContinuousClock.now.advanced(by: condition == "expired" ? .zero : .seconds(30))
            let authorization = AutomationMacPreparedRegistration.Authorization(deadline: deadline,
                revalidate: { try await lease.validate() })
            let task = Task { try await lifecycle.prepare(registerSubject: true, authorization: authorization) }
            await inventory.waitForEntry()
            if condition == "cancelled" { task.cancel() }
            if condition == "revoked" { await lease.revoke() }
            await inventory.finish()
            do { try await task.value; XCTFail("Registration admitted after " + condition) }
            catch {
                switch condition {
                case "cancelled": XCTAssertTrue(error is CancellationError)
                case "expired": XCTAssertEqual(error as? AutomationRPCError, .timedOut)
                default: XCTAssertEqual(error as? AutomationContractError, .unknownLease)
                }
            }
            XCTAssertEqual(events.snapshot(), [], condition)
        }
    }

    private let paths: Set<String> = ["/private/tmp/Subject.app/Contents/MacOS/Subject", "/private/tmp/Host-Runner.app/Contents/MacOS/Host-Runner"]
    private actor State {
        var frames: [AutomationMacProcessInventory]
        var calls = 0
        init(_ frames: [AutomationMacProcessInventory]) { self.frames = frames }
        func inspect() -> AutomationMacProcessInventory { defer { calls += 1 }; return frames[min(calls, frames.count - 1)] }
    }
    private func frame(_ records: [AutomationMacProcessInventory.Record] = [], complete: Bool = true) -> AutomationMacProcessInventory {
        var result = AutomationMacProcessInventory(userID: 501, complete: complete, processes: records)
        result.executableScope = paths.sorted()
        return result
    }
    private func record(_ path: String, pid: Int32 = 43) -> AutomationMacProcessInventory.Record {
        .init(identity: .init(pid: pid, startIdentity: "100:0"), userID: 501, executablePath: path)
    }
    private func lifecycle(_ state: State, validate: @escaping AutomationMacXCUITestLifecycle.Validator = {}) -> AutomationMacXCUITestLifecycle {
        .init(paths: paths, userID: 501, inspect: { await state.inspect() }, validate: validate)
    }
    func testPreparedSubjectAndRunnerRequireIndependentObservedAbsence() async throws {
        let live = paths.sorted().enumerated().map { record($0.element, pid: Int32(43 + $0.offset)) }
        let state = State([frame(), frame(live), frame()]), lifecycle = lifecycle(state)
        try await lifecycle.prepare()
        let released = await lifecycle.release()
        XCTAssertTrue(released)
        let calls = await state.calls
        XCTAssertEqual(calls, 3, "Release waits for independent subject and runner absence")
        let repeated = await lifecycle.release()
        XCTAssertTrue(repeated)
        let repeatedCalls = await state.calls
        XCTAssertEqual(repeatedCalls, calls)
    }
    func testAlreadyRunningSubjectOrRunnerCannotBeAdmittedOrTerminated() async throws {
        for path in paths {
            let state = State([frame([record(path)])]), lifecycle = lifecycle(state)
            do { try await lifecycle.prepare(); XCTFail("An existing process was admitted") }
            catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
            let released = await lifecycle.release()
            XCTAssertFalse(released)
        }
    }
    func testNoAdmissionIncompleteInventoryAndProductDriftCannotProveRelease() async throws {
        let neverStarted = lifecycle(State([frame()]))
        let released = await neverStarted.release()
        XCTAssertFalse(released)
        let incomplete = lifecycle(State([frame(complete: false)]))
        do { try await incomplete.prepare(); XCTFail("Incomplete inventory admitted") } catch {}
        let changed = lifecycle(State([frame()]), validate: { throw AutomationContractError.conflictingOperation })
        do { try await changed.prepare(); XCTFail("Changed products admitted") }
        catch { XCTAssertEqual(error as? AutomationContractError, .conflictingOperation) }
    }
    func testUnownedMatchingInstanceAfterAdmissionIsNeverTerminatedAndStaysUnreleased() async throws {
        // Absence at admission does not make a subsequently reopened instance run-owned.
        // The lifecycle has no signalling API, even when the new instance uses the exact bytes.
        let unowned = record(paths.sorted()[0], pid: 91)
        let state = State([frame(), frame([unowned])]), lifecycle = lifecycle(state)
        try await lifecycle.prepare()
        for _ in 0..<3 { let released = await lifecycle.release(); XCTAssertFalse(released) }
        let calls = await state.calls
        XCTAssertEqual(calls, 21, "Only bounded read-only observations are permitted; repeated release retains failure")
        let observations = await lifecycle.retainedObservations()
        XCTAssertEqual(observations.last?.inventory?.processes, [unowned])
    }
    func testOutOfScopeInventoryCannotAuthorizeTermination() async throws {
        let state = State([frame(), frame([record("/Applications/Other.app/Contents/MacOS/Other")])])
        let lifecycle = lifecycle(state)
        try await lifecycle.prepare()
        let released = await lifecycle.release()
        XCTAssertFalse(released)
    }
}
#endif
