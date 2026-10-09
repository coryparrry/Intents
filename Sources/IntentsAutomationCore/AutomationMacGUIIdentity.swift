#if os(macOS)
import Foundation
import CoreGraphics
import Security
import Darwin

/// Read-only admission for the caller's active local Quartz/security session.
/// This is identity evidence, not input permission or recipient qualification.
public enum AutomationMacGUIIdentity {
    struct Observation: Equatable, Sendable {
        let userID: UInt32, securitySessionID: UInt32
        let consoleSet: UInt32?
        let onConsole: Bool, loginDone: Bool
        let graphicAccess: Bool, root: Bool, remote: Bool
    }
    public static func currentTarget() throws -> TargetIdentity {
        let user = getuid()
        guard user == geteuid() else { throw AutomationContractError.invalidIdentity }
        let first = try observe(), second = try observe()
        guard first == second else { throw AutomationContractError.conflictingOperation }
        return try target(first, expectedUserID: user)
    }
    static func validate(_ selected: TargetIdentity) throws {
        guard selected == (try currentTarget()) else { throw AutomationContractError.conflictingOperation }
    }
    static func target(_ value: Observation, expectedUserID: UInt32) throws -> TargetIdentity {
        guard value.userID == expectedUserID, expectedUserID != 0,
              value.securitySessionID > 0, value.securitySessionID != UInt32.max,
              value.onConsole, value.loginDone, value.graphicAccess, !value.root, !value.remote else {
            throw AutomationContractError.missingEvidence("An active local Mac GUI session is required")
        }
        return .init(id: "host-macos-local", kind: .nativeMac,
            loginSession: "mac-gui-v1:\(value.userID):\(value.securitySessionID):\(value.consoleSet.map(String.init) ?? "none")")
    }
    static func decode(_ values: [String: Any], securitySessionID: UInt32, attributes: UInt32) throws -> Observation {
        func number(_ key: String) throws -> UInt32 {
            guard let value = values[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue.rounded() == value.doubleValue,
                  (0...Double(UInt32.max)).contains(value.doubleValue) else { throw AutomationContractError.missingEvidence("Invalid numeric GUI session field: " + key) }
            return value.uint32Value
        }
        func boolean(_ key: String) throws -> Bool {
            guard let value = values[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                throw AutomationContractError.missingEvidence("Invalid boolean GUI session field: " + key)
            }
            return value.boolValue
        }
        return try .init(userID: number(kCGSessionUserIDKey as String), securitySessionID: securitySessionID,
            consoleSet: values[kCGSessionConsoleSetKey as String] == nil ? nil : number(kCGSessionConsoleSetKey as String), onConsole: boolean(kCGSessionOnConsoleKey as String),
            loginDone: boolean(kCGSessionLoginDoneKey as String), graphicAccess: attributes & SessionAttributeBits.sessionHasGraphicAccess.rawValue != 0,
            root: attributes & SessionAttributeBits.sessionIsRoot.rawValue != 0, remote: attributes & SessionAttributeBits.sessionIsRemote.rawValue != 0)
    }
    private static func observe() throws -> Observation {
        var session: SecuritySessionId = 0, attributes: SessionAttributeBits = []
        guard SessionGetInfo(callerSecuritySession, &session, &attributes) == errSecSuccess,
              let values = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            throw AutomationContractError.missingEvidence("Mac GUI session identity is unavailable")
        }
        var after: SecuritySessionId = 0, afterAttributes: SessionAttributeBits = []
        guard SessionGetInfo(callerSecuritySession, &after, &afterAttributes) == errSecSuccess,
              session == after, attributes == afterAttributes else { throw AutomationContractError.conflictingOperation }
        return try decode(values, securitySessionID: session, attributes: attributes.rawValue)
    }
}

struct AutomationMacGUISubjectVerifier: AutomationSubjectVerifier {
    let subject: any AutomationSubjectVerifier
    let identity: @Sendable (TargetIdentity) throws -> Void
    func verify(app: AppIdentity, target: TargetIdentity) async throws {
        try identity(target)
        try await subject.verify(app: app, target: target)
        try identity(target)
    }
}
#endif
