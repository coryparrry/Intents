import Foundation

enum TaskControl: String, Codable, CaseIterable, Sendable {
    case correct, wrongRecord = "wrong-record", missingSave = "missing-save", intermittent
    var title: String {
        switch self {
        case .correct: "Correct"
        case .wrongRecord: "Wrong record"
        case .missingSave: "Missing save"
        case .intermittent: "Intermittent"
        }
    }
}
struct TaskRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var owner: String
    var completed = false
}
struct TaskDocument: Codable, Equatable, Sendable {
    var control: TaskControl = .correct
    var executionCount = 0
    var records: [TaskRecord] = []
}
enum TaskStoreError: Error { case invalidDocument, invalidInput, missingEntity }

/// Actual persistence for the seeded app. Queries always reload this document;
/// the deliberately broken controls affect the ordinary completion action.
struct TaskDiskStore: Sendable {
    let url: URL
    func read() throws -> TaskDocument {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_048_576 else { throw TaskStoreError.invalidDocument }
        let document = try JSONDecoder().decode(TaskDocument.self, from: data)
        guard document.executionCount >= 0, document.records.count <= 1000,
              Set(document.records.map(\.id)).count == document.records.count,
              document.records.allSatisfy({ UUID(uuidString: $0.id) != nil && !$0.title.isEmpty && $0.title.count <= 200 && ["Work", "Personal"].contains($0.owner) }) else { throw TaskStoreError.invalidDocument }
        return document
    }
    func create(title: String, owner: String) throws -> TaskDocument {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 200, ["Work", "Personal"].contains(owner) else { throw TaskStoreError.invalidInput }
        var document = try read()
        guard document.records.count < 1000 else { throw TaskStoreError.invalidDocument }
        document.records.append(.init(id: UUID().uuidString, title: title, owner: owner))
        try write(document); return document
    }
    func chooseControl(_ control: TaskControl) throws -> TaskDocument {
        var document = try read(); document.control = control; document.executionCount = 0
        try write(document); return document
    }
    func reset() throws -> TaskDocument {
        var document = try read(); document.records = []
        try write(document); return document
    }
    func complete(id: String) throws -> TaskDocument {
        var document = try read()
        guard let selected = document.records.firstIndex(where: { $0.id == id }), document.executionCount < Int.max else { throw TaskStoreError.missingEntity }
        document.executionCount += 1
        let before = document
        let affected: Int
        if document.control == .wrongRecord {
            guard let work = document.records.firstIndex(where: { $0.title == document.records[selected].title && $0.owner == "Work" }) else { throw TaskStoreError.missingEntity }
            affected = work // Seeded defect: title/account lookup ignores the passed entity ID.
        } else { affected = selected }
        document.records[affected].completed = true
        if document.control == .missingSave || (document.control == .intermittent && document.executionCount.isMultiple(of: 2) == false) {
            try write(before) // Retain only the control counter; the task change is deliberately unsaved.
        } else { try write(document) }
        return document
    }
    private func write(_ document: TaskDocument) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
    }
}
