#if os(macOS)
// The framework exposes its immutable option key as a legacy C global.
@preconcurrency import ApplicationServices

enum AutomationMacAccessibility {
    static func requestIfNeeded() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
#endif
