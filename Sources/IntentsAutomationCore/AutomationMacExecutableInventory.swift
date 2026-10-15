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
        func validatedRecord(_ identity: AutomationProcessIdentity, pid: Int32, path: String) throws -> Record {
            guard identity.pid == pid else { throw AutomationContractError.terminationUnverified }
            let record = Record(identity: identity, userID: userID, executablePath: path)
            try Self(userID: userID, complete: true, processes: [record]).validate(expectedUserID: userID)
            return record
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
                    if try inactive(pid) { continue }
                    guard let failure = error as? KernelObservationFailure,
                          failure.stage == .executablePath, failure.errorNumber == ENOENT,
                          try reader.excludesUnreadableExecutable?(pid, userID) == true else { throw error }
                    continue
                }
                guard validExecutablePath(path) else { throw AutomationContractError.terminationUnverified }
                guard paths.contains(path) else { continue }
                let record = try validatedRecord(reader.identity(pid, userID), pid: pid, path: path)
                let confirmedPath = try reader.executablePath(pid)
                guard validExecutablePath(confirmedPath) else { throw AutomationContractError.terminationUnverified }
                guard confirmedPath == path else {
                    // A valid exec transition invalidates the entire observation.
                    // Only a new complete scan can establish helper absence.
                    throw KernelObservationFailure(stage: .executableSetChanged, pid: pid, errorNumber: 0)
                }
                let confirmed = try validatedRecord(reader.identity(pid, userID), pid: pid, path: confirmedPath)
                guard confirmed.identity == record.identity else {
                    throw KernelObservationFailure(stage: .executableSetChanged, pid: pid, errorNumber: 0)
                }
                records.append(record)
            }
            return records
        }
        let first = try scan(), second = try scan()
        guard first == second else { throw KernelObservationFailure(stage: .executableSetChanged, pid: nil, errorNumber: 0) }
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
