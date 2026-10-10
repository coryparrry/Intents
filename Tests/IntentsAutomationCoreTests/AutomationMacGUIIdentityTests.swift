#if os(macOS)
import Foundation
import CoreGraphics
import XCTest
@testable import IntentsAutomationCore

final class AutomationMacGUIIdentityTests: XCTestCase, @unchecked Sendable {
    func observation(user: UInt32 = 501, session: UInt32 = 123, console: UInt32 = 0,
                     onConsole: Bool = true, done: Bool = true, graphic: Bool = true, root: Bool = false, remote: Bool = false) -> AutomationMacGUIIdentity.Observation {
        .init(userID: user, securitySessionID: session, consoleSet: console, onConsole: onConsole,
              loginDone: done, graphicAccess: graphic, root: root, remote: remote)
    }
    func values() -> [String: Any] {
        [kCGSessionUserIDKey as String: NSNumber(value: 501), kCGSessionConsoleSetKey as String: NSNumber(value: 0),
         kCGSessionOnConsoleKey as String: true, kCGSessionLoginDoneKey as String: true]
    }
    func testIdentityBindsUserSecuritySessionAndConsole() throws {
        let baseline = try AutomationMacGUIIdentity.target(observation(), expectedUserID: 501)
        XCTAssertEqual(baseline.loginSession, "mac-gui-v1:501:123:0")
        for changed in [observation(session: 124), observation(console: 1), observation(user: 502)] {
            XCTAssertNotEqual(baseline, try AutomationMacGUIIdentity.target(changed, expectedUserID: changed.userID))
        }
    }
    func testInactiveRemoteRootForeignAndReservedSessionsAreDenied() throws {
        for value in [observation(user: 0), observation(session: 0), observation(session: UInt32.max), observation(onConsole: false),
                      observation(done: false), observation(graphic: false), observation(root: true), observation(remote: true), observation(user: 502)] {
            XCTAssertThrowsError(try AutomationMacGUIIdentity.target(value, expectedUserID: 501))
        }
    }
    func testDictionaryRequiresExactBooleanAndUnsignedNumericProperties() throws {
        let valid = try AutomationMacGUIIdentity.decode(values(), securitySessionID: 123, attributes: 0x10)
        XCTAssertEqual(valid, observation())
        for (key, value) in [(kCGSessionUserIDKey as String, NSNumber(value: true)), (kCGSessionUserIDKey as String, NSNumber(value: -1)),
                             (kCGSessionConsoleSetKey as String, NSNumber(value: 0.5)), (kCGSessionOnConsoleKey as String, NSNumber(value: 1)),
                             (kCGSessionLoginDoneKey as String, "true" as Any)] {
            var invalid = values(); invalid[key] = value
            XCTAssertThrowsError(try AutomationMacGUIIdentity.decode(invalid, securitySessionID: 123, attributes: 0x10))
        }
        for key in values().keys {
            var missing = values(); missing.removeValue(forKey: key)
            if key == kCGSessionConsoleSetKey as String { XCTAssertNil(try AutomationMacGUIIdentity.decode(missing, securitySessionID: 123, attributes: 0x10).consoleSet) }
            else { XCTAssertThrowsError(try AutomationMacGUIIdentity.decode(missing, securitySessionID: 123, attributes: 0x10)) }
        }
    }
    final class Identity: @unchecked Sendable {
        private let lock = NSLock(); private var calls = 0
        func validate(_ target: TargetIdentity) throws {
            lock.lock(); defer { lock.unlock() }; calls += 1
            if calls > 1 { throw AutomationContractError.conflictingOperation }
        }
    }
    actor Subject: AutomationSubjectVerifier {
        var calls = 0
        func verify(app: AppIdentity, target: TargetIdentity) async throws { calls += 1 }
        func count() -> Int { calls }
    }
    func testSessionChangeDuringSubjectCheckCannotAuthorizeLaterInput() async throws {
        let underlying = Subject(), identity = Identity()
        let verifier = AutomationMacGUISubjectVerifier(subject: underlying, identity: { try identity.validate($0) })
        do { try await verifier.verify(app: .init(logicalID: "fixture", bundleID: "example.Fixture", platform: "macos"),
            target: .init(id: "host-macos-local", kind: .nativeMac, loginSession: "mac-gui-v1:501:123:0")); XCTFail("Changed GUI identity accepted") } catch {}
        let count = await underlying.count(); XCTAssertEqual(count, 1)
    }
    func testCurrentSessionReadOnlyOptIn() throws {
        guard ProcessInfo.processInfo.environment["INTENTS_MAC_GUI_IDENTITY_PROBE"] == "1" else { throw XCTSkip("Read-only current GUI identity opt-in") }
        let selected = try AutomationMacGUIIdentity.currentTarget()
        try AutomationMacGUIIdentity.validate(selected)
        XCTAssertEqual(selected.kind, .nativeMac); XCTAssertTrue(selected.loginSession?.hasPrefix("mac-gui-v1:") == true)
        var forged = selected; forged.loginSession = "caller-supplied-login"
        XCTAssertThrowsError(try AutomationMacGUIIdentity.validate(forged))
    }
}
#endif
