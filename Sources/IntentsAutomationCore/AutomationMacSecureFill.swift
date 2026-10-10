#if os(macOS)
@preconcurrency import AppKit
import ApplicationServices
import Darwin
import Foundation
import Security

/// Private native production adapter; no executable, worker payload or raw stream.
/// The host must already have Accessibility permission. This never prompts for it.
enum AutomationMacSecureFill {
    struct Application: Equatable, Sendable {
        let bundleID: String?, canonicalBundlePath: String?, isTerminated: Bool
    }
    struct SigningUniques: Equatable, Sendable { let disk: Data, running: Data }
    struct ProcessOwner: Equatable, Sendable { let uid: uid_t, ruid: uid_t }
    enum AttributeValue: Equatable, Sendable { case string(String), bool(Bool), other }
    /// Native AX reads and writes; `nil` or `false` means the call did not succeed.
    struct Accessibility<Element>: Sendable {
        let application: @Sendable (pid_t) -> Element
        let setTimeout: @Sendable (Element) -> Bool
        let element: @Sendable (Element, Float, Float) -> Element?
        let pid: @Sendable (Element) -> pid_t?
        let attribute: @Sendable (Element, String) -> AttributeValue?
        let parent: @Sendable (Element) -> Element?
        let isValueSettable: @Sendable (Element) -> Bool?
        let setValue: @Sendable (Element, String) -> Bool
        let same: @Sendable (Element, Element) -> Bool
    }
    /// Workspace, process and code-signing reads; `nil` means the call did not succeed.
    struct Platform<Element>: Sendable {
        let validateTarget: @Sendable (TargetIdentity) throws -> Void
        let isAccessibilityTrusted: @Sendable () -> Bool
        let frontmostPID: @Sendable () -> pid_t?
        let inspect: @Sendable (pid_t) -> AutomationProcessIdentity?
        let presence: @Sendable (AutomationProcessIdentity) -> AutomationProcessIdentity.Presence
        let application: @Sendable (pid_t) -> Application?
        let productDigest: @Sendable (URL) throws -> String
        /// Code-directory uniques of the strictly valid disk bundle and the valid running guest.
        let signingUniques: @Sendable (URL, pid_t) -> SigningUniques?
        let processOwner: @Sendable (pid_t) -> ProcessOwner?
        let currentUID: @Sendable () -> uid_t
        let accessibility: Accessibility<Element>
    }
    struct Context<Element>: Sendable {
        let approval: RunApproval
        let process: AutomationProcessIdentity
        let leaseFence: AutomationNativeInputLeaseFence
        let x: Float, y: Float
        let platform: Platform<Element>
        private var ax: Accessibility<Element> { platform.accessibility }
        func verify() throws {
            try AutomationNativeSecretDeadline.check()
            try platform.validateTarget(approval.target)
            guard leaseFence.isCurrent else { throw AutomationSecretFillSession.Failure.denied }
            guard platform.isAccessibilityTrusted(), platform.presence(process) == .matching,
                  let app = platform.application(process.pid), !app.isTerminated,
                  app.bundleID == approval.app.bundleID,
                  app.canonicalBundlePath == approval.app.canonicalBundlePath,
                  platform.frontmostPID() == process.pid,
                  let path = approval.app.canonicalBundlePath,
                  try platform.productDigest(URL(fileURLWithPath: path)) == approval.app.productDigest,
                  platform.presence(process) == .matching else { throw AutomationSecretFillSession.Failure.denied }
            try verifyRunningCode()
            let user = platform.currentUID()
            guard let owner = platform.processOwner(process.pid), owner.uid == user, owner.ruid == user else {
                throw AutomationSecretFillSession.Failure.denied
            }
            try AutomationNativeSecretDeadline.check()
        }
        private func verifyRunningCode() throws {
            // Signing information comes from disk; dynamic validity must match it to the running code first.
            guard let path = approval.app.canonicalBundlePath,
                  let uniques = platform.signingUniques(URL(fileURLWithPath: path), process.pid),
                  !uniques.disk.isEmpty, uniques.disk == uniques.running else { throw AutomationSecretFillSession.Failure.denied }
            if let approved = approval.app.codeDirectoryIdentity {
                guard uniques.disk.map({ String(format: "%02x", $0) }).joined() == approved else { throw AutomationSecretFillSession.Failure.denied }
            }
            try AutomationNativeSecretDeadline.check()
        }
        func resolve() throws -> Element {
            try verify()
            let app = ax.application(process.pid)
            try timeout(app)
            guard let result = ax.element(app, x, y) else { throw AutomationSecretFillSession.Failure.denied }
            try timeout(result); return result
        }
        func verifyField(_ element: Element) throws {
            try verify(); try timeout(element)
            func attribute(_ item: Element, _ name: String) throws -> AttributeValue {
                try AutomationNativeSecretDeadline.check(); try timeout(item)
                guard let value = ax.attribute(item, name) else { throw AutomationSecretFillSession.Failure.denied }
                return value
            }
            guard ax.pid(element) == process.pid,
                  try attribute(element, kAXRoleAttribute) == .string(kAXTextFieldRole),
                  try attribute(element, kAXSubroleAttribute) == .string(kAXSecureTextFieldSubrole),
                  try attribute(element, kAXEnabledAttribute) == .bool(true),
                  ax.isValueSettable(element) == true else {
                throw AutomationSecretFillSession.Failure.denied
            }
            var current = element
            for _ in 0..<32 {
                try AutomationNativeSecretDeadline.check()
                guard ax.pid(current) == process.pid else { throw AutomationSecretFillSession.Failure.denied }
                if try attribute(current, kAXRoleAttribute) == .string(kAXApplicationRole) {
                    try verify(); return
                }
                try AutomationNativeSecretDeadline.check(); try timeout(current)
                guard let parent = ax.parent(current) else { throw AutomationSecretFillSession.Failure.denied }
                current = parent
            }
            throw AutomationSecretFillSession.Failure.denied
        }
        func replace(_ element: Element, value: String) throws {
            try verifyField(element)
            let fresh = try resolve()
            guard ax.same(element, fresh) else { throw AutomationSecretFillSession.Failure.denied }
            try verifyField(fresh)
            try AutomationNativeSecretDeadline.check()
            guard leaseFence.isCurrent else { throw AutomationSecretFillSession.Failure.denied }
            try AutomationNativeSecretDeadline.check()
            guard ax.setValue(element, value) else { throw AutomationSecretFillSession.Failure.outcomeUnresolved }
        }
        private func timeout(_ element: Element) throws {
            guard ax.setTimeout(element) else { throw AutomationSecretFillSession.Failure.denied }
        }
    }
    static func capture(approval: RunApproval, scope: AutomationScope, leaseFence: AutomationNativeInputLeaseFence, x: Double, y: Double) async throws -> AutomationMacSecureSink<AXUIElement> {
        try await capture(approval: approval, scope: scope, leaseFence: leaseFence, x: x, y: y, platform: .live)
    }
    static func capture<Element>(approval: RunApproval, scope: AutomationScope, leaseFence: AutomationNativeInputLeaseFence,
                                 x: Double, y: Double, platform: Platform<Element>) async throws -> AutomationMacSecureSink<Element> {
        guard leaseFence.lease.runID == approval.runID, leaseFence.lease.target == approval.target,
              leaseFence.lease.control == .ui, leaseFence.lease.generation == scope.leaseGeneration, leaseFence.isCurrent,
              x.isFinite, y.isFinite, abs(x) <= 1_000_000, abs(y) <= 1_000_000,
              let pid = platform.frontmostPID(), let process = platform.inspect(pid) else {
            throw AutomationSecretFillSession.Failure.denied
        }
        let context = Context(approval: approval, process: process, leaseFence: leaseFence, x: Float(x), y: Float(y), platform: platform)
        let owner = try AutomationMacSecureSink<Element>(approval: approval, scope: scope, dependencies: .init(
            checkInputOwnership: { guard leaseFence.isCurrent else { throw AutomationSecretFillSession.Failure.denied } },
            validateContext: { try context.verify() }, resolve: { try context.resolve() }, verify: { try context.verifyField($0) },
            same: { platform.accessibility.same($0, $1) }, replace: { try context.replace($0, value: $1) }))
        try await owner.open(); return owner
    }
}

extension AutomationMacSecureFill.Platform where Element == AXUIElement {
    static var live: Self {
        .init(
            validateTarget: { try AutomationMacGUIIdentity.validate($0) },
            isAccessibilityTrusted: { AXIsProcessTrusted() },
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            inspect: { AutomationProcessIdentity.inspect(pid: $0) },
            presence: { $0.presence() },
            application: { pid in
                guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
                return .init(bundleID: app.bundleIdentifier,
                             canonicalBundlePath: app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path,
                             isTerminated: app.isTerminated)
            },
            productDigest: { try AutomationProductDigest.compute(bundle: $0, version: 2) },
            signingUniques: { liveSigningUniques(bundle: $0, pid: $1) },
            processOwner: { pid in
                var info = proc_bsdinfo()
                guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
                return .init(uid: info.pbi_uid, ruid: info.pbi_ruid)
            },
            currentUID: { getuid() },
            accessibility: .live)
    }
    static func liveSigningUniques(bundle: URL, pid: pid_t) -> AutomationMacSecureFill.SigningUniques? {
        var disk: SecStaticCode?, running: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &disk) == errSecSuccess, let disk,
              SecStaticCodeCheckValidity(disk, flags, nil) == errSecSuccess,
              SecCodeCopyGuestWithAttributes(nil, attributes, [], &running) == errSecSuccess, let running,
              SecCodeCheckValidity(running, [], nil) == errSecSuccess else { return nil }
        var runningStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(running, [], &runningStatic) == errSecSuccess, let runningStatic else { return nil }
        var diskInfo: CFDictionary?, runningInfo: CFDictionary?
        guard SecCodeCopySigningInformation(disk, SecCSFlags(rawValue: kSecCSSigningInformation), &diskInfo) == errSecSuccess,
              SecCodeCopySigningInformation(runningStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &runningInfo) == errSecSuccess,
              let expected = (diskInfo as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              let actual = (runningInfo as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
        return .init(disk: expected, running: actual)
    }
}

extension AutomationMacSecureFill.Accessibility where Element == AXUIElement {
    static var live: Self {
        .init(
            application: { AXUIElementCreateApplication($0) },
            setTimeout: { AXUIElementSetMessagingTimeout($0, 0.25) == .success },
            element: { app, x, y in
                var result: AXUIElement?
                guard AXUIElementCopyElementAtPosition(app, x, y, &result) == .success else { return nil }
                return result
            },
            pid: { element in
                var pid: pid_t = 0
                return AXUIElementGetPid(element, &pid) == .success ? pid : nil
            },
            attribute: { element, name in
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
                if let string = value as? String { return .string(string) }
                if let bool = value as? Bool { return .bool(bool) }
                return .other
            },
            parent: { element in
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success, let value,
                      CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
                return unsafeBitCast(value, to: AXUIElement.self)
            },
            isValueSettable: { element in
                var settable = DarwinBoolean(false)
                return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success ? settable.boolValue : nil
            },
            setValue: { AXUIElementSetAttributeValue($0, kAXValueAttribute as CFString, $1 as CFString) == .success },
            same: { CFEqual($0, $1) })
    }
}
#endif
