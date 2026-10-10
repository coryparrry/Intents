#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationPhysicalDeviceReleaseTests: XCTestCase, @unchecked Sendable {
    typealias Controller = AutomationPhysicalRunnerVerifier.Controller
    typealias Observation = AutomationPhysicalRunnerVerifier.BatchObservation
    private let target = TargetIdentity(id: "00008140-000E4D803C0B001C", kind: .physical)
    private let controllers = [Controller(bundleID: "example.Runner", executableName: "Runner"),
                               Controller(bundleID: "example.Tests.xctrunner", executableName: "Tests-Runner", ownedPID: 42)]
    private func observation(targetID: String? = nil, deviceID: String = "1AD4F755-6F58-58E5-AC71-B1EDFECADA93", absent: Bool = true) -> Observation {
        .init(targetID: targetID ?? target.id, deviceIdentifier: deviceID,
              controllers: controllers.map { .init(controller: $0, absent: absent) },
              appsSHA256: String(repeating: "a", count: 64), processesSHA256: String(repeating: "b", count: 64))
    }
    private actor Spy {
        var calls = 0, drains = 0
        var observations: [Observation]
        var drainResults: [Bool]
        var failure = false
        init(_ observations: [Observation], drainResults: [Bool] = []) {
            self.observations = observations; self.drainResults = drainResults
        }
        func inspect(_ target: TargetIdentity, _ controllers: [Controller]) throws -> Observation {
            let result = try inspectWithoutScopeCheck(target, controllers)
            XCTAssertEqual(result.targetID, target.id)
            return result
        }
        func inspectWithoutScopeCheck(_ target: TargetIdentity, _ controllers: [Controller]) throws -> Observation {
            calls += 1
            if failure || observations.isEmpty { throw AutomationContractError.terminationUnverified }
            return observations.removeFirst()
        }
        func drain() -> Bool { drains += 1; return drainResults.isEmpty ? true : drainResults.removeFirst() }
        func counts() -> (Int, Int) { (calls, drains) }
    }
    private func verifier(_ spy: Spy) throws -> AutomationPhysicalDeviceReleaseVerifier {
        try .init(controllers: controllers, inspect: { try await spy.inspect($0, $1) }, drain: { await spy.drain() })
    }

    func testReleaseRequiresPreparedScopeAndCompleteFreshControllerAbsence() async throws {
        let spy = Spy([observation(), observation()]), verifier = try verifier(spy)
        let unprepared = await verifier.verifyReleased(target: target, controllerBundleIDs: controllers.map(\.bundleID))
        XCTAssertFalse(unprepared)
        try await verifier.prepare(target: target, controllerBundleIDs: controllers.map(\.bundleID))
        let released = await verifier.verifyReleased(target: target, controllerBundleIDs: Array(controllers.map(\.bundleID).reversed()))
        XCTAssertTrue(released)
        let counts = await spy.counts(); XCTAssertEqual(counts.0, 2); XCTAssertEqual(counts.1, 2)
    }
    func testPresentControllerDuringPreparationNeverGrantsRelease() async throws {
        let spy = Spy([observation(absent: false)]), verifier = try verifier(spy)
        do { try await verifier.prepare(target: target, controllerBundleIDs: controllers.map(\.bundleID)); XCTFail("Present runner accepted") }
        catch { XCTAssertEqual(error as? AutomationContractError, .terminationUnverified) }
        let released = await verifier.verifyReleased(target: target, controllerBundleIDs: controllers.map(\.bundleID))
        XCTAssertFalse(released)
        let counts = await spy.counts(); XCTAssertEqual(counts.0, 1)
    }
    func testReappearingControllerOrDeviceIdentityChangeRefusesRelease() async throws {
        for changed in [observation(absent: false), observation(deviceID: UUID().uuidString)] {
            let spy = Spy([observation(), changed]), verifier = try verifier(spy)
            try await verifier.prepare(target: target, controllerBundleIDs: controllers.map(\.bundleID))
            let released = await verifier.verifyReleased(target: target, controllerBundleIDs: controllers.map(\.bundleID))
            XCTAssertFalse(released)
        }
    }
    func testIncompleteForeignOrMalformedObservationRefusesRelease() async throws {
        var missing = observation(); missing.controllers.removeLast()
        var duplicate = observation(); duplicate.controllers[1] = duplicate.controllers[0]
        var hash = observation(); hash.processesSHA256 = "unknown"
        var foreign = observation(); foreign.targetID = "another-device"
        for changed in [missing, duplicate, hash, foreign, observation(deviceID: "not-a-uuid")] {
            let spy = Spy([observation(), changed])
            // Use a raw injected inspector for this test so a foreign response reaches the verifier.
            let verifier = try AutomationPhysicalDeviceReleaseVerifier(controllers: controllers,
                inspect: { target, controllers in try await spy.inspectWithoutScopeCheck(target, controllers) }, drain: { await spy.drain() })
            try await verifier.prepare(target: target, controllerBundleIDs: controllers.map(\.bundleID))
            let released = await verifier.verifyReleased(target: target, controllerBundleIDs: controllers.map(\.bundleID))
            XCTAssertFalse(released)
        }
    }
    func testTargetAndControllerScopeCannotBeChangedAfterPreparation() async throws {
        let spy = Spy([observation()]), verifier = try verifier(spy)
        try await verifier.prepare(target: target, controllerBundleIDs: controllers.map(\.bundleID))
        var changed = target; changed.toolchain = "/other/developer"
        for scope in [controllers.map(\.bundleID).dropLast().map { $0 }, [controllers[0].bundleID, controllers[0].bundleID], ["example.Foreign"]] {
            let released = await verifier.verifyReleased(target: target, controllerBundleIDs: scope); XCTAssertFalse(released)
        }
        let changedTarget = await verifier.verifyReleased(target: changed, controllerBundleIDs: controllers.map(\.bundleID)); XCTAssertFalse(changedTarget)
        let counts = await spy.counts(); XCTAssertEqual(counts.0, 1)
    }
    func testUnprovedLocalInspectorDrainRemainsLatched() async throws {
        let spy = Spy([observation(), observation()], drainResults: [true, false, true]), verifier = try verifier(spy)
        try await verifier.prepare(target: target, controllerBundleIDs: controllers.map(\.bundleID))
        let first = await verifier.verifyReleased(target: target, controllerBundleIDs: controllers.map(\.bundleID))
        let second = await verifier.verifyReleased(target: target, controllerBundleIDs: controllers.map(\.bundleID))
        XCTAssertFalse(first); XCTAssertFalse(second)
        let counts = await spy.counts(); XCTAssertEqual(counts.0, 2)
    }
    func testInspectorFailureFailsClosedAndStillDrains() async throws {
        let spy = Spy([observation()]), verifier = try verifier(spy)
        try await verifier.prepare(target: target, controllerBundleIDs: controllers.map(\.bundleID))
        let released = await verifier.verifyReleased(target: target, controllerBundleIDs: controllers.map(\.bundleID))
        XCTAssertFalse(released)
        let counts = await spy.counts(); XCTAssertEqual(counts.0, 2); XCTAssertEqual(counts.1, 2)
    }
    func testMalformedControllerScopesAreRejectedBeforeInventory() throws {
        for scope in [[], [controllers[0], controllers[0]], [.init(bundleID: "invalid", executableName: "Runner")],
                      [.init(bundleID: "example.Invalid_Runner", executableName: "Runner")],
                      [.init(bundleID: "example.Runner", executableName: "../Runner")], [.init(bundleID: "example.Runner", executableName: "Runner", ownedPID: 0)]] {
            XCTAssertThrowsError(try AutomationPhysicalDeviceReleaseVerifier(controllers: scope,
                inspect: { _, _ in XCTFail("Unexpected inventory"); throw AutomationContractError.terminationUnverified }, drain: { true }))
        }
    }
    private actor Gate {
        var pending: CheckedContinuation<Void, Never>?
        func wait(_ started: AsyncStream<Void>.Continuation) async {
            await withCheckedContinuation { continuation in pending = continuation; started.yield(()) }
        }
        func resume() { pending?.resume(); pending = nil }
    }
    func testConcurrentPrepareAndReleaseCannotInterleaveInspections() async throws {
        let gate = Gate(), started = AsyncStream<Void>.makeStream()
        let expected = observation()
        let verifier = try AutomationPhysicalDeviceReleaseVerifier(controllers: controllers,
            inspect: { _, _ in await gate.wait(started.continuation); return expected }, drain: { true })
        let target = self.target, bundleIDs = controllers.map(\.bundleID)
        let preparation = Task { try await verifier.prepare(target: target, controllerBundleIDs: bundleIDs) }
        for await _ in started.stream { break }
        let released = await verifier.verifyReleased(target: target, controllerBundleIDs: bundleIDs)
        XCTAssertFalse(released)
        do { try await verifier.prepare(target: target, controllerBundleIDs: bundleIDs); XCTFail("Concurrent preparation accepted") }
        catch { XCTAssertEqual(error as? AutomationContractError, .terminationUnverified) }
        await gate.resume(); try await preparation.value
        started.continuation.finish()
    }
}
#endif
