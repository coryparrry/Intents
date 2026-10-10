import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// PID plus kernel start identity; never authorises termination from a PID alone.
public struct AutomationProcessIdentity: Codable, Equatable, Sendable {
    public var pid: Int32
    public var startIdentity: String
    public enum Presence: Sendable { case matching, absent, replaced, unknown }
    public init(pid: Int32, startIdentity: String) { self.pid = pid; self.startIdentity = startIdentity }
    public static func current() throws -> Self {
        guard let identity = inspect(pid: getpid()) else { throw AutomationContractError.invalidIdentity }
        return identity
    }
    public static func inspect(pid: Int32) -> Self? {
        guard pid > 0 else { return nil }
        #if canImport(Darwin)
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Self(pid: pid, startIdentity: "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)")
        #else
        // Include the boot ID: Linux start ticks alone can repeat after a reboot.
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let end = stat.lastIndex(of: ")"),
              let boot = try? String(contentsOfFile: "/proc/sys/kernel/random/boot_id", encoding: .utf8) else { return nil }
        let fields = stat[stat.index(after: end)...].split(separator: " ")
        guard fields.count > 19 else { return nil }
        return Self(pid: pid, startIdentity: "\(boot.trimmingCharacters(in: .whitespacesAndNewlines)):\(fields[19])")
        #endif
    }
    public func presence() -> Presence {
        guard pid > 0, !startIdentity.isEmpty else { return .unknown }
        if let actual = Self.inspect(pid: pid) { return actual == self ? .matching : .replaced }
        if kill(pid, 0) == -1 && errno == ESRCH { return .absent }
        return .unknown
    }
}
