import Foundation
import SwiftData

@Model
final class TaskRecord {
    @Attribute(.unique) var taskID: String
    var title: String
    var isComplete: Bool
    var updatedAt: Date
    var invocationContext: String
    var actionReceiptID: String

    init(
        taskID: String,
        title: String,
        isComplete: Bool,
        updatedAt: Date = .now,
        invocationContext: String = "",
        actionReceiptID: String = ""
    ) {
        self.taskID = taskID
        self.title = title
        self.isComplete = isComplete
        self.updatedAt = updatedAt
        self.invocationContext = invocationContext
        self.actionReceiptID = actionReceiptID
    }
}

struct TaskSnapshot: Equatable, Sendable {
    let id: String
    let title: String
    let isComplete: Bool
    let updatedAt: Date
    let invocationContext: String
    let actionReceiptID: String
}

enum ExampleTasks {
    static let initial: [(id: String, title: String)] = [
        ("task-001", "Buy milk"),
        ("task-002", "Book appointment")
    ]
}
