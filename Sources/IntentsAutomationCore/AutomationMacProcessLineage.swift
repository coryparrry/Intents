#if os(macOS)
import Foundation

/// Sampled kernel ancestry for an exact owned command. This is diagnostic data,
/// not launch permission, termination authority or proof of complete child closure.
/// Children born and reparented between samples can remain unobserved.
struct AutomationMacProcessLineage: Sendable {
    struct Observation: Equatable, Sendable {
        let sequence: Int
        let rootPresent: Bool
        let matchingObservedDescendants: [AutomationProcessIdentity]
        let absentOrReplacedObservedDescendants: [AutomationProcessIdentity]
    }
    private struct Member: Sendable {
        let identity: AutomationProcessIdentity
    }
    let root: AutomationProcessIdentity
    let userID: UInt32
    let rootExecutablePath: String
    private var members: [Member] = []
    private var observations = 0

    init(root: AutomationProcessIdentity, userID: UInt32, rootExecutablePath: String) throws {
        guard root.pid > 0, Self.start(root) != nil, AutomationMacProcessInventory.validExecutablePath(rootExecutablePath) else {
            throw AutomationContractError.invalidIdentity
        }
        self.root = root; self.userID = userID; self.rootExecutablePath = rootExecutablePath
    }

    mutating func observe(_ inventory: AutomationMacProcessInventory) throws -> Observation {
        try Task.checkCancellation()
        guard observations < 256 else { throw AutomationContractError.terminationUnverified }
        try inventory.validate(expectedUserID: userID)
        // Missing legacy ancestry must never be interpreted as an empty child set.
        guard inventory.processes.allSatisfy({ $0.parentPID != nil && $0.status != nil }) else {
            throw AutomationContractError.terminationUnverified
        }
        let records = Dictionary(uniqueKeysWithValues: inventory.processes.map { ($0.identity.pid, $0) })
        let rootRecord = records[root.pid]
        let rootPresent = rootRecord?.identity == root
        if observations == 0 {
            guard rootPresent, rootRecord?.executablePath == rootExecutablePath else { throw AutomationContractError.invalidIdentity }
        }
        if rootPresent, rootRecord?.executablePath != rootExecutablePath { throw AutomationContractError.conflictingOperation }
        var children: [Int32: [AutomationMacProcessInventory.Record]] = [:]
        for record in inventory.processes {
            let parentPID = record.parentPID!
            if let parent = records[parentPID] {
                guard let parentStart = Self.start(parent.identity), let childStart = Self.start(record.identity),
                      parentStart <= childStart else { throw AutomationContractError.terminationUnverified }
                children[parentPID, default: []].append(record)
            }
        }
        // Check every ancestry chain before retaining anything; malformed cycles
        // must not be hidden by a visited-set traversal or partial ledger update.
        var checked = Set<Int32>()
        for record in inventory.processes where !checked.contains(record.identity.pid) {
            var visited = Set<Int32>(), cursor: Int32? = record.identity.pid
            while let pid = cursor, !checked.contains(pid), let current = records[pid] {
                guard visited.insert(pid).inserted else { throw AutomationContractError.terminationUnverified }
                cursor = current.parentPID
            }
            checked.formUnion(visited)
        }
        var next = members
        var retained: [Int32: Set<String>] = [:]
        for member in next { retained[member.identity.pid, default: []].insert(member.identity.startIdentity) }
        var queue = next.compactMap { records[$0.identity.pid]?.identity == $0.identity ? $0.identity.pid : nil }
        if rootPresent { queue.append(root.pid) }
        var visited = Set<Int32>()
        var position = 0
        while position < queue.count {
            try Task.checkCancellation()
            let parent = queue[position]; position += 1
            guard visited.insert(parent).inserted else { continue }
            for child in children[parent, default: []] {
                // A matching previously observed child remains tracked after it
                // reparents. A replacement PID never inherits its predecessor's lineage.
                guard child.identity != root else { throw AutomationContractError.terminationUnverified }
                if retained[child.identity.pid]?.contains(child.identity.startIdentity) != true {
                    guard next.count < 1024 else { throw AutomationContractError.terminationUnverified }
                    next.append(.init(identity: child.identity))
                    retained[child.identity.pid, default: []].insert(child.identity.startIdentity)
                }
                queue.append(child.identity.pid)
            }
        }
        func sorted(_ values: [AutomationProcessIdentity]) -> [AutomationProcessIdentity] {
            values.sorted { $0.pid == $1.pid ? $0.startIdentity < $1.startIdentity : $0.pid < $1.pid }
        }
        let matching = next.filter { records[$0.identity.pid]?.identity == $0.identity }.map(\.identity)
        let absent = next.filter { records[$0.identity.pid]?.identity != $0.identity }.map(\.identity)
        members = next; observations += 1
        return .init(sequence: observations, rootPresent: rootPresent,
                     matchingObservedDescendants: sorted(matching), absentOrReplacedObservedDescendants: sorted(absent))
    }

    private struct Start: Comparable {
        let seconds: UInt64, microseconds: UInt32
        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.seconds == rhs.seconds ? lhs.microseconds < rhs.microseconds : lhs.seconds < rhs.seconds
        }
    }
    private static func start(_ identity: AutomationProcessIdentity) -> Start? {
        let fields = identity.startIdentity.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2, let seconds = UInt64(fields[0]), seconds > 0, String(seconds) == fields[0],
              let micros = UInt32(fields[1]), micros <= 999_999, String(micros) == fields[1] else { return nil }
        return .init(seconds: seconds, microseconds: micros)
    }
}
#endif
