import Foundation
import CoreFoundation

/// Reconstruct native error payloads instead of forwarding exception descriptions.
enum TelemetryCrashPrivacy {
    nonisolated static func properties(_ raw: [String: Any]) -> [String: Any]? {
        guard raw["$exception_level"] as? String == "fatal",
              let exceptions = raw["$exception_list"] as? [[String: Any]],
              !exceptions.isEmpty, exceptions.count <= 4 else { return nil }
        let safeExceptions = exceptions.compactMap(exception)
        guard !safeExceptions.isEmpty else { return nil }
        var result: [String: Any] = ["$exception_level": "fatal", "$exception_list": safeExceptions]
        let addresses = Set(safeExceptions.flatMap { entry -> [String] in
            let frames = (entry["stacktrace"] as? [String: Any])?["frames"] as? [[String: Any]] ?? []
            return frames.compactMap { $0["image_addr"] as? String }
        })
        if let images = raw["$debug_images"] as? [[String: Any]], images.count <= 512 {
            let safe = images.compactMap(image).filter { addresses.contains($0["image_addr"] as? String ?? "") }.prefix(128)
            if !safe.isEmpty { result["$debug_images"] = Array(safe) }
        }
        return result
    }

    nonisolated private static func exception(_ raw: [String: Any]) -> [String: Any]? {
        guard let mechanism = raw["mechanism"] as? [String: Any],
              let kind = mechanism["type"] as? String,
              ["signal", "mach_exception", "nsexception"].contains(kind),
              mechanism["handled"] as? Bool == false else { return nil }
        let knownTypes: Set<String> = ["SIGABRT", "SIGBUS", "SIGFPE", "SIGILL", "SIGSEGV", "SIGTRAP", "SIGSYS",
            "EXC_BAD_ACCESS", "EXC_BAD_INSTRUCTION", "EXC_ARITHMETIC", "EXC_BREAKPOINT", "EXC_CRASH", "EXC_RESOURCE", "EXC_GUARD",
            "Fatal error", "Assertion failed", "Precondition failed", "NSInvalidArgumentException", "NSRangeException", "NSInternalInconsistencyException"]
        let original = raw["type"] as? String ?? ""
        let type = knownTypes.contains(original) ? original : (kind == "nsexception" ? "NSException" : "NativeCrash")
        var safe: [String: Any] = ["type": type, "value": "Native crash; message omitted for privacy",
            "mechanism": ["type": kind, "handled": false, "synthetic": false]]
        if let stack = raw["stacktrace"] as? [String: Any], let frames = stack["frames"] as? [[String: Any]], frames.count <= 4_096 {
            // SDK frames are outermost first: keep the crashing end of a deep stack.
            let safeFrames = frames.suffix(256).compactMap(frame)
            if !safeFrames.isEmpty { safe["stacktrace"] = ["type": "raw", "frames": safeFrames] }
        }
        return safe
    }

    nonisolated private static func frame(_ raw: [String: Any]) -> [String: Any]? {
        guard let instruction = address(raw["instruction_addr"]) else { return nil }
        var safe: [String: Any] = ["instruction_addr": instruction, "platform": "apple"]
        for key in ["image_addr", "symbol_addr"] {
            if let value = address(raw[key]) { safe[key] = value }
        }
        if let inApp = raw["in_app"] as? Bool { safe["in_app"] = inApp }
        return safe
    }

    nonisolated private static func image(_ raw: [String: Any]) -> [String: Any]? {
        guard raw["type"] as? String == "macho", let load = address(raw["image_addr"]),
              let id = (raw["debug_id"] as? String).flatMap(UUID.init(uuidString:)),
              let size = raw["image_size"] as? NSNumber, CFGetTypeID(size) != CFBooleanGetTypeID(),
              size.doubleValue > 0, size.doubleValue <= 4_294_967_296,
              size.doubleValue.rounded(.towardZero) == size.doubleValue else { return nil }
        // dSYM lookup uses debug_id; paths and arbitrary module names are unnecessary.
        var safe: [String: Any] = ["type": "macho", "code_file": "native-image", "debug_id": id.uuidString,
            "image_addr": load, "image_size": size.uint64Value]
        if let preferred = address(raw["image_vmaddr"]) { safe["image_vmaddr"] = preferred }
        if let arch = raw["arch"] as? String, ["arm64", "arm64e", "x86_64", "x86_64h"].contains(arch) { safe["arch"] = arch }
        return safe
    }

    nonisolated private static func address(_ value: Any?) -> String? {
        guard let value = value as? String, value.hasPrefix("0x"), (3...18).contains(value.count),
              value.dropFirst(2).allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let number = UInt64(value.dropFirst(2), radix: 16) else { return nil }
        return "0x" + String(number, radix: 16)
    }
}
