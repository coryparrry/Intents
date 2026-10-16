import Foundation

/// Selection history is context only. Reopening always performs a new inspection
/// and cannot restore an approval, prepared build, or dispatch authority.
public struct AutomationRecentApplication: Codable, Equatable, Identifiable, Sendable {
    public let path: String
    public let name: String
    public let bookmark: Data?
    public let selectedAt: Date
    public var id: String { path }
    public init(path: String, name: String, bookmark: Data?, selectedAt: Date = Date()) {
        self.path = path; self.name = name; self.bookmark = bookmark; self.selectedAt = selectedAt
    }
    func validate() throws {
        guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\0"),
              !name.isEmpty, name.utf8.count <= 1024, bookmark?.count ?? 0 <= 65_536,
              selectedAt.timeIntervalSince1970.isFinite else { throw AutomationContractError.invalidIdentity }
    }
}

public struct AutomationRecentApplicationStore: Sendable {
    private struct Archive: Codable { var version = 1; var applications: [AutomationRecentApplication] }
    private let file: AutomationDurableFile
    public init(supportRoot: URL) throws {
        file = try .init(url: supportRoot.appendingPathComponent("recent-applications.json"), maximumBytes: 1_048_576)
    }
    public func read() throws -> [AutomationRecentApplication] {
        guard let data = try file.read() else { return [] }
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        guard archive.version == 1, archive.applications.count <= 10,
              Set(archive.applications.map(\.id)).count == archive.applications.count else { throw AutomationContractError.invalidIdentity }
        try archive.applications.forEach { try $0.validate() }
        return archive.applications
    }
    @discardableResult public func remember(_ application: AutomationRecentApplication) throws -> [AutomationRecentApplication] {
        try application.validate()
        return try file.withLock {
            let history = Array(([application] + (try read()).filter { $0.id != application.id }).prefix(10))
            try file.write(JSONEncoder().encode(Archive(applications: history)))
            return history
        }
    }
    @discardableResult public func forget(path: String) throws -> [AutomationRecentApplication] {
        try file.withLock {
            let history = try read().filter { $0.path != path }
            try file.write(JSONEncoder().encode(Archive(applications: history)))
            return history
        }
    }
}
