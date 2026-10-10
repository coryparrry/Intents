import Foundation

/// Durable dispatch intent precedes effects; unfinished dispatches never permit repetition.
public actor AutomationJournal {
    public struct Entry: Codable, Equatable, Sendable {
        public var operationID: String
        public var payloadDigest: String
        public var state: State
        public var response: AutomationValue?
        public enum State: String, Codable, Sendable { case dispatched, completed, unresolved }
    }
    private let file: AutomationDurableFile
    public init(url: URL) throws {
        file = try .init(url: url, maximumBytes: 16_777_216)
        _ = try file.withLock { try Self.load(file) }
    }
    public func begin(operationID: String, digest: String) throws -> AutomationValue? {
        guard digest.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              !operationID.isEmpty, operationID.utf8.count <= 1024 else { throw AutomationContractError.invalidIdentity }
        return try transaction { entries in
            if let prior = entries[operationID] {
                guard prior.payloadDigest == digest else { throw AutomationContractError.conflictingOperation }
                guard prior.state == .completed, let response = prior.response else { throw AutomationContractError.ambiguousDispatch }
                return response
            }
            guard entries.count < 10_000 else { throw AutomationContractError.invalidIdentity }
            entries[operationID] = .init(operationID: operationID, payloadDigest: digest, state: .dispatched)
            return nil
        }
    }
    public func complete(operationID: String, digest: String, response: AutomationValue) throws {
        try transaction { entries in
            guard let previous = entries[operationID], previous.payloadDigest == digest else { throw AutomationContractError.conflictingOperation }
            if previous.state == .completed {
                guard previous.response == response else { throw AutomationContractError.conflictingOperation }; return
            }
            entries[operationID] = .init(operationID: operationID, payloadDigest: digest, state: .completed, response: response)
        }
    }
    public func unresolvedEntries() throws -> [Entry] {
        try file.withLock { try Self.load(file).values.filter { $0.state != .completed }.sorted { $0.operationID < $1.operationID } }
    }
    private func transaction<T>(_ body: (inout [String: Entry]) throws -> T) throws -> T {
        try file.withLock {
            var entries = try Self.load(file)
            let result = try body(&entries)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try file.write(encoder.encode(entries)); return result
        }
    }
    private static func load(_ file: AutomationDurableFile) throws -> [String: Entry] {
        let entries = try file.read().map { try JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        guard entries.count <= 10_000 else { throw AutomationContractError.invalidIdentity }
        for (key, entry) in entries {
            guard key == entry.operationID, !key.isEmpty, key.utf8.count <= 1024,
                  entry.payloadDigest.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
                  (entry.state == .completed) == (entry.response != nil) else { throw AutomationContractError.invalidIdentity }
        }
        return entries
    }
}
