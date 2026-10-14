import Foundation
import XCTest
@testable import IntentsAutomationHostContracts

@MainActor
final class HostFixtureRegistrationTests: XCTestCase {
    private let fixture = "com.coryparry.IntentsAutomation.AutomationFixture"
    private func metadataError(domain: String = "AppIntentsServicesMetadataErrorDomain", code: Int = 400,
                               bundle: String? = nil) -> NSError {
        NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: "\(bundle ?? fixture) is not present"])
    }
    func testFixedProbeReturnsExactValueAndRecordsSuccess() async throws {
        var diagnostics: [HostFixtureRegistration.Attempt] = [], realActions = 0
        try await HostFixtureRegistration.wait(bundleID: fixture, deadline: .now.advanced(by: .seconds(120)), probe: { intent, value in
            XCTAssertEqual(intent, "EchoTextIntent"); XCTAssertEqual(value, "registration-ready")
            return value
        }, pause: { _ in XCTFail("Successful readiness must not pause") }, record: { diagnostics.append($0) })
        realActions += 1
        XCTAssertEqual(realActions, 1); XCTAssertEqual(diagnostics.count, 1)
        XCTAssertTrue(diagnostics[0].succeeded); XCTAssertNil(diagnostics[0].error)
    }
    func testOnlyDiagnosticRetriesBeforeOneRealAction() async throws {
        var probes = 0, pauses: [Duration] = [], diagnostics: [HostFixtureRegistration.Attempt] = [], realActions = 0
        try await HostFixtureRegistration.wait(bundleID: fixture, deadline: .now.advanced(by: .seconds(120)), probe: { _, value in
            probes += 1
            if probes < 3 { throw self.metadataError() }
            return value
        }, pause: { pauses.append($0) }, record: { diagnostics.append($0) })
        realActions += 1
        XCTAssertEqual(probes, 3); XCTAssertEqual(pauses, [.seconds(5), .seconds(5)]); XCTAssertEqual(realActions, 1)
        XCTAssertEqual(diagnostics.map(\.index), [1, 2, 3]); XCTAssertEqual(diagnostics.map(\.succeeded), [false, false, true])
    }
    func testThreeFailedDiagnosticsNeverInvokeRealAction() async throws {
        var probes = 0, pauses = 0, diagnostics = 0, realActions = 0
        do {
            try await HostFixtureRegistration.wait(bundleID: fixture, deadline: .now.advanced(by: .seconds(120)), probe: { _, _ in
                probes += 1; throw self.metadataError()
            }, pause: { _ in pauses += 1 }, record: { _ in diagnostics += 1 })
            realActions += 1
            XCTFail("Exhausted readiness must fail")
        } catch { XCTAssertEqual((error as NSError).code, 400) }
        XCTAssertEqual(probes, 3); XCTAssertEqual(pauses, 2); XCTAssertEqual(diagnostics, 3); XCTAssertEqual(realActions, 0)
    }
    func testWrongBundleNeverInvokesProbe() async {
        do {
            try await HostFixtureRegistration.wait(bundleID: "other.fixture", deadline: .now.advanced(by: .seconds(120)), probe: { _, _ in
                XCTFail("Wrong bundle must not dispatch a diagnostic"); return "registration-ready"
            })
            XCTFail("Wrong bundle accepted")
        } catch { XCTAssertEqual(error as? HostFixtureRegistration.Failure, .wrongBundle) }
    }
    func testWrongOutputAndUnrelatedErrorsNeverRetry() async {
        let failures: [NSError?] = [nil, metadataError(domain: "other"), metadataError(code: 401), metadataError(bundle: "other.fixture")]
        for failure in failures {
            var probes = 0, diagnostics = 0
            do {
                try await HostFixtureRegistration.wait(bundleID: fixture, deadline: .now.advanced(by: .seconds(120)), probe: { _, _ in
                    probes += 1
                    if let failure { throw failure }
                    return "wrong output"
                }, pause: { _ in XCTFail("Unrelated errors must not pause") }, record: { _ in diagnostics += 1 })
                XCTFail("Invalid readiness accepted")
            } catch {
                if failure == nil { XCTAssertEqual(error as? HostFixtureRegistration.Failure, .wrongOutput) }
            }
            XCTAssertEqual(probes, 1); XCTAssertEqual(diagnostics, 1)
        }
    }
    func testDeadlineBeforeAndAfterProbePreventsFurtherWork() async {
        let start = ContinuousClock.now, deadline = start.advanced(by: .seconds(120))
        for initiallyExpired in [true, false] {
            var now = initiallyExpired ? deadline : start, probes = 0, diagnostics = 0
            do {
                try await HostFixtureRegistration.wait(bundleID: fixture, deadline: deadline, now: { now }, probe: { _, value in
                    probes += 1; now = deadline; return value
                }, pause: { _ in XCTFail("Expired readiness must not pause") }, record: { _ in diagnostics += 1 })
                XCTFail("Expired deadline accepted")
            } catch { XCTAssertEqual(error as? HostFixtureRegistration.Failure, .deadlineExceeded) }
            XCTAssertEqual(probes, initiallyExpired ? 0 : 1); XCTAssertEqual(diagnostics, probes)
        }
    }
    func testDeadlineAfterPauseStopsBeforeAnotherProbe() async {
        let start = ContinuousClock.now, deadline = start.advanced(by: .seconds(120))
        var now = start, probes = 0, pauses = 0
        do {
            try await HostFixtureRegistration.wait(bundleID: fixture, deadline: deadline, now: { now }, probe: { _, _ in
                probes += 1; throw self.metadataError()
            }, pause: { _ in pauses += 1; now = deadline })
            XCTFail("Expired pause accepted")
        } catch { XCTAssertEqual(error as? HostFixtureRegistration.Failure, .deadlineExceeded) }
        XCTAssertEqual(probes, 1); XCTAssertEqual(pauses, 1)
    }
    func testInsufficientPauseBudgetNeverSleepsOrRetries() async {
        let start = ContinuousClock.now
        do {
            try await HostFixtureRegistration.wait(bundleID: fixture, deadline: start.advanced(by: .seconds(5)), now: { start }, probe: { _, _ in
                throw self.metadataError()
            }, pause: { _ in XCTFail("Pause does not fit") })
            XCTFail("Insufficient deadline accepted")
        } catch { XCTAssertEqual(error as? HostFixtureRegistration.Failure, .deadlineExceeded) }
    }
    func testCancellationInProbeAndPausePropagatesWithoutRetry() async {
        for cancelDuringPause in [false, true] {
            var probes = 0, pauses = 0
            do {
                try await HostFixtureRegistration.wait(bundleID: fixture, deadline: .now.advanced(by: .seconds(120)), probe: { _, _ in
                    probes += 1
                    if cancelDuringPause { throw self.metadataError() }
                    throw CancellationError()
                }, pause: { _ in pauses += 1; throw CancellationError() })
                XCTFail("Cancellation ignored")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(probes, 1); XCTAssertEqual(pauses, cancelDuringPause ? 1 : 0)
        }
    }
    func testCancelledTaskNeverInvokesProbe() async {
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await HostFixtureRegistration.wait(bundleID: fixture, deadline: .now.advanced(by: .seconds(120)), probe: { _, _ in
                XCTFail("Cancelled task dispatched diagnostic"); return "registration-ready"
            })
        }
        do { try await task.value; XCTFail("Cancellation ignored") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testSimulatorOnlyCallerRunsPreflightBeforeActualDispatchLoop() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Integration/AutomationHost/SegmentTests.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("#if INTENTS_AUTOMATION_CI_FIXTURE && os(iOS) && targetEnvironment(simulator)"))
        let activation = try XCTUnwrap(source.range(of: "app.activate()"))
        let readiness = try XCTUnwrap(source.range(of: "HostFixtureRegistration.wait("))
        let operations = try XCTUnwrap(source.range(of: "for operation in plan.operations"))
        let marker = try XCTUnwrap(source.range(of: "intents-dispatch-"))
        XCTAssertLessThan(activation.lowerBound, readiness.lowerBound)
        XCTAssertLessThan(readiness.lowerBound, operations.lowerBound)
        XCTAssertLessThan(operations.lowerBound, marker.lowerBound)
        XCTAssertTrue(source.contains("intents-fixture-registration-"))
    }
}
