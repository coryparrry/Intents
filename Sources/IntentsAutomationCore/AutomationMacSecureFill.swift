#if os(macOS)
@preconcurrency import AppKit
import ApplicationServices
import Darwin
import Foundation
import Security

/// Private native production adapter; no executable, worker payload or raw stream.
/// The host must already have Accessibility permission. This never prompts for it.
enum AutomationMacSecureFill {
    struct Context: Sendable {
        let approval: RunApproval
        let process: AutomationProcessIdentity
        let leaseFence: AutomationNativeInputLeaseFence
        let x: Float, y: Float
        func verify() throws {
            try AutomationNativeSecretDeadline.check()
            try AutomationMacGUIIdentity.validate(approval.target)
            guard leaseFence.isCurrent else { throw AutomationSecretFillSession.Failure.denied }
            guard AXIsProcessTrusted(), process.presence() == .matching,
                  let app = NSRunningApplication(processIdentifier: process.pid), !app.isTerminated,
                  app.bundleIdentifier == approval.app.bundleID,
                  app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == approval.app.canonicalBundlePath,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == process.pid,
                  let path = approval.app.canonicalBundlePath,
                  try AutomationProductDigest.compute(bundle: URL(fileURLWithPath: path), version: 2) == approval.app.productDigest,
                  process.presence() == .matching else { throw AutomationSecretFillSession.Failure.denied }
            try verifyRunningCode()
            var info = proc_bsdinfo()
            guard proc_pidinfo(process.pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                  info.pbi_uid == getuid(), info.pbi_ruid == getuid() else { throw AutomationSecretFillSession.Failure.denied }
            try AutomationNativeSecretDeadline.check()
        }
        private func verifyRunningCode() throws {
            guard let path = approval.app.canonicalBundlePath else { throw AutomationSecretFillSession.Failure.denied }
            var disk: SecStaticCode?, running: SecCode?
            let attributes = [kSecGuestAttributePid as String: NSNumber(value: process.pid)] as CFDictionary
            let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
            guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &disk) == errSecSuccess, let disk,
                  SecStaticCodeCheckValidity(disk, flags, nil) == errSecSuccess,
                  SecCodeCopyGuestWithAttributes(nil, attributes, [], &running) == errSecSuccess, let running,
                  SecCodeCheckValidity(running, [], nil) == errSecSuccess else { throw AutomationSecretFillSession.Failure.denied }
            var runningStatic: SecStaticCode?
            guard SecCodeCopyStaticCode(running, [], &runningStatic) == errSecSuccess, let runningStatic else { throw AutomationSecretFillSession.Failure.denied }
            // Signing information comes from disk; dynamic validity above must match it to the running code first.
            var diskInfo: CFDictionary?, runningInfo: CFDictionary?
            guard SecCodeCopySigningInformation(disk, SecCSFlags(rawValue: kSecCSSigningInformation), &diskInfo) == errSecSuccess,
                  SecCodeCopySigningInformation(runningStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &runningInfo) == errSecSuccess,
                  let expected = (diskInfo as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
                  let actual = (runningInfo as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
                  !expected.isEmpty, expected == actual else { throw AutomationSecretFillSession.Failure.denied }
            if let approved = approval.app.codeDirectoryIdentity {
                guard expected.map({ String(format: "%02x", $0) }).joined() == approved else { throw AutomationSecretFillSession.Failure.denied }
            }
            try AutomationNativeSecretDeadline.check()
        }
        func resolve() throws -> AXUIElement {
            try verify()
            let app = AXUIElementCreateApplication(process.pid)
            try timeout(app)
            var result: AXUIElement?
            guard AXUIElementCopyElementAtPosition(app, x, y, &result) == .success, let result else {
                throw AutomationSecretFillSession.Failure.denied
            }
            try timeout(result); return result
        }
        func verifyField(_ element: AXUIElement) throws {
            try verify(); try timeout(element)
            func attribute(_ item: AXUIElement, _ name: CFString) throws -> CFTypeRef {
                try AutomationNativeSecretDeadline.check(); try timeout(item)
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(item, name, &value) == .success, let value else {
                    throw AutomationSecretFillSession.Failure.denied
                }
                return value
            }
            var pid: pid_t = 0, settable = DarwinBoolean(false)
            guard AXUIElementGetPid(element, &pid) == .success, pid == process.pid,
                  try attribute(element, kAXRoleAttribute as CFString) as? String == kAXTextFieldRole as String,
                  try attribute(element, kAXSubroleAttribute as CFString) as? String == kAXSecureTextFieldSubrole as String,
                  try attribute(element, kAXEnabledAttribute as CFString) as? Bool == true,
                  AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue else {
                throw AutomationSecretFillSession.Failure.denied
            }
            var current = element
            for _ in 0..<32 {
                try AutomationNativeSecretDeadline.check()
                guard AXUIElementGetPid(current, &pid) == .success, pid == process.pid else { throw AutomationSecretFillSession.Failure.denied }
                if try attribute(current, kAXRoleAttribute as CFString) as? String == kAXApplicationRole as String {
                    try verify(); return
                }
                let parent = try attribute(current, kAXParentAttribute as CFString)
                guard CFGetTypeID(parent) == AXUIElementGetTypeID() else { throw AutomationSecretFillSession.Failure.denied }
                current = unsafeBitCast(parent, to: AXUIElement.self)
            }
            throw AutomationSecretFillSession.Failure.denied
        }
        func replace(_ element: AXUIElement, value: String) throws {
            try verifyField(element)
            let fresh = try resolve()
            guard CFEqual(element, fresh) else { throw AutomationSecretFillSession.Failure.denied }
            try verifyField(fresh)
            try AutomationNativeSecretDeadline.check()
            guard leaseFence.isCurrent else { throw AutomationSecretFillSession.Failure.denied }
            try AutomationNativeSecretDeadline.check()
            guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString) == .success else {
                throw AutomationSecretFillSession.Failure.outcomeUnresolved
            }
        }
        private func timeout(_ element: AXUIElement) throws {
            guard AXUIElementSetMessagingTimeout(element, 0.25) == .success else { throw AutomationSecretFillSession.Failure.denied }
        }
    }
    static func capture(approval: RunApproval, scope: AutomationScope, leaseFence: AutomationNativeInputLeaseFence, x: Double, y: Double) async throws -> AutomationMacSecureSink<AXUIElement> {
        guard leaseFence.lease.runID == approval.runID, leaseFence.lease.target == approval.target,
              leaseFence.lease.control == .ui, leaseFence.lease.generation == scope.leaseGeneration, leaseFence.isCurrent,
              x.isFinite, y.isFinite, abs(x) <= 1_000_000, abs(y) <= 1_000_000,
              let app = NSWorkspace.shared.frontmostApplication, let process = AutomationProcessIdentity.inspect(pid: app.processIdentifier) else {
            throw AutomationSecretFillSession.Failure.denied
        }
        let context = Context(approval: approval, process: process, leaseFence: leaseFence, x: Float(x), y: Float(y))
        let owner = try AutomationMacSecureSink<AXUIElement>(approval: approval, scope: scope, dependencies: .init(
            checkInputOwnership: { guard leaseFence.isCurrent else { throw AutomationSecretFillSession.Failure.denied } },
            validateContext: { try context.verify() }, resolve: { try context.resolve() }, verify: { try context.verifyField($0) },
            same: { CFEqual($0, $1) }, replace: { try context.replace($0, value: $1) }))
        try await owner.open(); return owner
    }
}
#endif
