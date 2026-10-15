#if os(macOS)
import Foundation
import Darwin

/// Kernel observations only; never terminate, activate or inspect application UI.
public struct AutomationMacProcessInventory: Codable, Equatable, Sendable {
    public struct ProcessFacts: Codable, Equatable, Sendable {
        public var pid: Int32
        public var parentPID: Int32
        public var userID: UInt32
        public var status: UInt32
        public var startIdentity: String?
        /// SDK sys/proc.h: SZOMB means awaiting collection by the parent, not absent.
        public var awaitingParentCollection: Bool { status == UInt32(SZOMB) }
    }
    public struct KernelObservationFailure: Error, Codable, Equatable, Sendable, CustomStringConvertible {
        public enum Stage: String, Codable, Sendable { case metadata, identityFields, executablePath, codeIdentity, pidList, absenceUnconfirmed, executableSetChanged }
        public let stage: Stage
        public let pid: Int32?
        public let errorNumber: Int32
        public var process: ProcessFacts? = nil
        public var description: String { "Mac kernel observation failed: \(stage.rawValue), pid=\(pid.map(String.init) ?? "none"), errno=\(errorNumber), parent=\(process.map { String($0.parentPID) } ?? "unknown"), state=\(process.map { String($0.status) } ?? "unknown")" }
    }
    public struct Record: Codable, Equatable, Sendable {
        public var identity: AutomationProcessIdentity
        public var userID: UInt32
        public var executablePath: String
        /// Older retained inventories lack ancestry and cannot support lineage observations.
        public var parentPID: Int32?
        /// Sampled process state; runnable/sleeping transitions are not identity changes.
        public var status: UInt32?
        public init(identity: AutomationProcessIdentity, userID: UInt32, executablePath: String, parentPID: Int32? = nil, status: UInt32? = nil) {
            self.identity = identity; self.userID = userID; self.executablePath = executablePath
            self.parentPID = parentPID; self.status = status
        }
    }
    public var userID: UInt32
    public var complete: Bool
    public var processes: [Record]
    /// Non-nil observations cover only these live executables, not the entire UID.
    public var executableScope: [String]? = nil
    /// Retained to decode and validate previously saved observation evidence.
    public struct Reconciliation: Codable, Equatable, Sendable {
        public var attempts: Int
        public var confirmedDisappearedPIDs: [Int32]
    }
    public var reconciliation: Reconciliation?
    public init(userID: UInt32, complete: Bool, processes: [Record]) {
        self.userID = userID; self.complete = complete; self.processes = processes
        reconciliation = nil
    }

    public func validate(expectedUserID: UInt32, matchingExecutablePaths: Set<String>? = nil) throws {
        if let executableScope {
            guard !executableScope.isEmpty, executableScope.count <= 10,
                  Set(executableScope).count == executableScope.count,
                  Set(executableScope) == matchingExecutablePaths,
                  executableScope.allSatisfy(Self.validExecutablePath), reconciliation == nil,
                  processes.allSatisfy({ executableScope.contains($0.executablePath) }) else {
                throw AutomationContractError.terminationUnverified
            }
        }
        guard complete, userID == expectedUserID, executableScope != nil || !processes.isEmpty, processes.count <= 8192,
              Set(processes.map(\.identity.pid)).count == processes.count else {
            throw AutomationContractError.terminationUnverified
        }
        if let reconciliation {
            let disappeared = reconciliation.confirmedDisappearedPIDs
            guard (1...3).contains(reconciliation.attempts), disappeared.count <= 128,
                  Set(disappeared).count == disappeared.count, disappeared.allSatisfy({ $0 > 0 }),
                  Set(disappeared).isDisjoint(with: Set(processes.map(\.identity.pid))),
                  reconciliation.attempts != 1 || disappeared.isEmpty else {
                throw AutomationContractError.terminationUnverified
            }
        }
        for record in processes {
            let components = record.identity.startIdentity.split(separator: ":", omittingEmptySubsequences: false)
            guard record.userID == userID, record.identity.pid > 0, components.count == 2,
                  let seconds = UInt64(components[0]), seconds > 0, String(seconds) == components[0],
                  let microseconds = UInt32(components[1]), microseconds <= 999_999, String(microseconds) == components[1],
                  Self.validExecutablePath(record.executablePath) else {
                throw AutomationContractError.terminationUnverified
            }
            if record.parentPID != nil || record.status != nil {
                guard let parent = record.parentPID, parent >= 0, parent != record.identity.pid,
                      let status = record.status, (1...5).contains(status) else { throw AutomationContractError.terminationUnverified }
            }
        }
    }
    static func validExecutablePath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 4096 && !path.contains("\0") &&
            !path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    struct Reader: Sendable {
        var processIDs: @Sendable (UInt32) throws -> Set<Int32>
        var identity: @Sendable (Int32, UInt32) throws -> AutomationProcessIdentity
        var executablePath: @Sendable (Int32) throws -> String
        var excludesUnreadableExecutable: (@Sendable (Int32, UInt32) throws -> Bool)? = nil
    }

    /// Two matching, bounded observations of the selected executables;
    /// never an atomic kernel snapshot or an entire-user census.
    public static func currentUser(watchedExecutablePaths: Set<String>) throws -> Self {
        try collectExecutables(userID: getuid(), paths: watchedExecutablePaths,
            reader: .init(processIDs: { try processIDs(userID: $0) },
                identity: { try info(pid: $0, userID: $1) }, executablePath: { try executablePath(pid: $0) },
                excludesUnreadableExecutable: { pid, userID in
                    try AutomationMacExecutableCodeIdentity.excludes(pid: pid, userID: userID, paths: watchedExecutablePaths)
                }),
            inactive: { try inactiveProcess(pid: $0, userID: getuid()) })
    }
    private static func executablePath(pid: Int32) throws -> String {
        // proc_info.h defines PROC_PIDPATHINFO_MAXSIZE as (4 * MAXPATHLEN);
        // Clang does not import that expression macro into Swift.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { throw failure(stage: .executablePath, pid: pid, errorNumber: errno) }
        guard length > 0, length < buffer.count, let terminator = buffer.firstIndex(of: 0), terminator > 0,
              let path = String(bytes: buffer[..<terminator].map { UInt8(bitPattern: $0) }, encoding: .utf8),
              validExecutablePath(path) else { throw AutomationContractError.terminationUnverified }
        return path
    }
    static func info(pid: Int32, userID: UInt32) throws -> AutomationProcessIdentity {
        let facts = try processFacts(pid: pid, userID: userID)
        guard let start = facts.startIdentity else { throw AutomationContractError.terminationUnverified }
        return .init(pid: pid, startIdentity: start)
    }
    private static func processFacts(pid: Int32, userID: UInt32) throws -> ProcessFacts {
        var record = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &record, size) == size else {
            throw failure(stage: .metadata, pid: pid, errorNumber: errno)
        }
        guard record.pbi_pid == UInt32(pid), record.pbi_uid == userID, record.pbi_start_tvsec > 0,
              record.pbi_start_tvusec <= 999_999, record.pbi_ppid <= UInt32(Int32.max) else { throw failure(stage: .identityFields, pid: pid, errorNumber: 0) }
        return .init(pid: pid, parentPID: Int32(record.pbi_ppid), userID: userID, status: record.pbi_status,
                     startIdentity: "\(record.pbi_start_tvsec):\(record.pbi_start_tvusec)")
    }
    /// A second sample for diagnostics only. It never repairs a failed inventory
    /// or authorizes reaping; PID reuse can make it differ from the failed sample.
    private static func failure(stage: KernelObservationFailure.Stage, pid: Int32, errorNumber: Int32) -> KernelObservationFailure {
        var value = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        var facts: ProcessFacts?
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, size) == size, value.pbi_pid == UInt32(pid),
           value.pbi_ppid <= UInt32(Int32.max) {
            let start = value.pbi_start_tvsec > 0 && value.pbi_start_tvusec <= 999_999 ? "\(value.pbi_start_tvsec):\(value.pbi_start_tvusec)" : nil
            facts = .init(pid: pid, parentPID: Int32(value.pbi_ppid), userID: value.pbi_uid, status: value.pbi_status, startIdentity: start)
        }
        return .init(stage: stage, pid: pid, errorNumber: errorNumber, process: facts)
    }
    private static func processIDs(userID: UInt32) throws -> Set<Int32> {
        let size = Int32(MemoryLayout<Int32>.size)
        let requested = proc_listpids(UInt32(PROC_UID_ONLY), userID, nil, 0)
        guard requested > 0 else { throw KernelObservationFailure(stage: .pidList, pid: nil, errorNumber: errno) }
        guard requested > 0, requested % size == 0, requested <= 8192 * size else {
            throw AutomationContractError.terminationUnverified
        }
        // Reserve bounded room for growth; a full buffer cannot establish completeness.
        let capacity = min(8192, Int(requested / size) + 128)
        var pids = [Int32](repeating: 0, count: capacity)
        let returned = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), userID, $0.baseAddress, Int32($0.count)) }
        guard returned > 0 else { throw KernelObservationFailure(stage: .pidList, pid: nil, errorNumber: errno) }
        guard returned > 0, returned % size == 0, returned < capacity * Int(size) else {
            throw AutomationContractError.terminationUnverified
        }
        let values = Array(pids.prefix(Int(returned / size))).filter { $0 > 0 }
        let result = Set(values)
        guard result.count == values.count, result.contains(getpid()) else { throw AutomationContractError.terminationUnverified }
        return result
    }
}
#endif
