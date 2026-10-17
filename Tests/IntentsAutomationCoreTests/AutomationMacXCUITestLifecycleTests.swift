#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationMacXCUITestLifecycleTests: XCTestCase, @unchecked Sendable {
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
