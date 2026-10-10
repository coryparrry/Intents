#if os(macOS)
import Foundation
import Darwin

extension AutomationMacProcessInventory {
    /// Observe only the selected executables. Other apps need no identity/ancestry
    /// inspection and their starts/exits do not invalidate this observation.
    /// This proves neither descendant closure nor reaping; owned PID checks do that separately.
    static func collectExecutables(userID: UInt32, paths: Set<String>, reader: Reader,
                                   inactive: (Int32) throws -> Bool) throws -> Self {
        guard (1...10).contains(paths.count), paths.allSatisfy(validExecutablePath) else {
            throw AutomationContractError.invalidIdentity
        }
        func scan() throws -> [Record] {
            try Task.checkCancellation()
            let pids = try reader.processIDs(userID)
            guard !pids.isEmpty, pids.count <= 8192, pids.allSatisfy({ $0 > 0 }) else {
                throw AutomationContractError.terminationUnverified
            }
            var records: [Record] = []
            for pid in pids.sorted() {
                try Task.checkCancellation()
                let path: String
                do { path = try reader.executablePath(pid) }
                catch {
                    // A missing path alone never means absent. A kernel-confirmed
                    // exited process cannot execute a helper, even before its parent reaps it.
                    guard try inactive(pid) else { throw error }
                    continue
                }
                guard validExecutablePath(path) else { throw AutomationContractError.terminationUnverified }
                guard paths.contains(path) else { continue }
                let identity = try reader.identity(pid, userID)
                guard identity.pid == pid, try reader.executablePath(pid) == path,
                      try reader.identity(pid, userID) == identity else {
                    throw AutomationContractError.terminationUnverified
                }
                records.append(.init(identity: identity, userID: userID, executablePath: path))
            }
            return records
        }
        let first = try scan(), second = try scan()
        guard first == second else { throw AutomationContractError.terminationUnverified }
        var result = Self(userID: userID, complete: true, processes: first)
        result.executableScope = paths.sorted()
        try result.validate(expectedUserID: userID, matchingExecutablePaths: paths)
        return result
    }

    /// Unlike proc_pidinfo, KERN_PROC_PID can describe unreaped children.
    /// Two matching terminal observations avoid treating a reused PID as a zombie.
    static func inactiveProcess(pid: Int32, userID: UInt32) throws -> Bool {
        func sample() throws -> kinfo_proc? {
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            var value = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
            guard sysctl(&mib, UInt32(mib.count), &value, &size, nil, 0) == 0 else {
                throw KernelObservationFailure(stage: .metadata, pid: pid, errorNumber: errno)
            }
            if size == 0 { return nil }
            guard size == MemoryLayout<kinfo_proc>.size, value.kp_proc.p_pid == pid,
                  value.kp_eproc.e_ucred.cr_uid == userID else { throw AutomationContractError.terminationUnverified }
            return value
        }
        guard let first = try sample() else { return kill(pid, 0) == -1 && errno == ESRCH }
        guard first.kp_proc.p_stat == SZOMB, let second = try sample() else { return false }
        let a = first.kp_proc.p_un.__p_starttime, b = second.kp_proc.p_un.__p_starttime
        return second.kp_proc.p_stat == SZOMB && first.kp_eproc.e_ppid == second.kp_eproc.e_ppid &&
            a.tv_sec > 0 && a.tv_sec == b.tv_sec && a.tv_usec == b.tv_usec
    }
}
#endif
