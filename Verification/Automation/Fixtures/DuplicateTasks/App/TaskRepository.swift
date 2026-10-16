import Foundation
import Observation

@MainActor @Observable
final class TaskRepository {
    static let shared = TaskRepository()
    private let disk = TaskDiskStore(url: URL.documentsDirectory.appendingPathComponent("DuplicateTasks.json"))
    private(set) var document = TaskDocument()
    var error: String?
    func reload() { update { try disk.read() } }
    func create(title: String, owner: String) { update { try disk.create(title: title, owner: owner) } }
    func chooseControl(_ control: TaskControl) { update { try disk.chooseControl(control) } }
    func reset() { update { try disk.reset() } }
    func persistedDocument() throws -> TaskDocument { try disk.read() }
    func complete(id: String) throws {
        document = try disk.complete(id: id)
        error = nil
    }
    private func update(_ operation: () throws -> TaskDocument) {
        do { document = try operation(); error = nil }
        catch { self.error = "Task data could not be saved or read: \(error)" }
    }
}
