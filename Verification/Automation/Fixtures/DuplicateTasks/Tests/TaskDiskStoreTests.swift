import XCTest
@testable import DuplicateTasksModel

final class TaskDiskStoreTests: XCTestCase {
    private var root: URL!
    private var store: TaskDiskStore!
    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = .init(url: root.appendingPathComponent("tasks.json"))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    private func seed(_ control: TaskControl) throws -> TaskRecord {
        _ = try store.chooseControl(control); _ = try store.reset()
        _ = try store.create(title: "Send invoice", owner: "Work")
        let document = try store.create(title: "Send invoice", owner: "Personal")
        XCTAssertEqual(Set(document.records.map(\.id)).count, 2)
        return try XCTUnwrap(document.records.first { $0.owner == "Personal" })
    }
    func testCorrectActionPersistsOnlyActualSelectedIDAcrossNewReaders() throws {
        let personal = try seed(.correct)
        _ = try store.complete(id: personal.id)
        let records = try TaskDiskStore(url: store.url).read().records
        XCTAssertEqual(records.first { $0.id == personal.id }?.completed, true)
        XCTAssertEqual(records.first { $0.owner == "Work" }?.completed, false)
    }
    func testWrongRecordControlIgnoresCorrectEntityAndChangesWorkRecord() throws {
        let personal = try seed(.wrongRecord)
        _ = try store.complete(id: personal.id)
        let records = try TaskDiskStore(url: store.url).read().records
        XCTAssertEqual(records.first { $0.id == personal.id }?.completed, false)
        XCTAssertEqual(records.first { $0.owner == "Work" }?.completed, true)
    }
    func testMissingSaveControlReturnsChangedStateButFreshDiskReaderRemainsFalse() throws {
        let personal = try seed(.missingSave)
        let returned = try store.complete(id: personal.id)
        XCTAssertEqual(returned.records.first { $0.id == personal.id }?.completed, true)
        XCTAssertTrue(try TaskDiskStore(url: store.url).read().records.allSatisfy { !$0.completed })
    }
    func testIntermittentControlUsesFreshRecordsAndPreservesOnlyCounterAcrossReset() throws {
        let first = try seed(.intermittent)
        _ = try store.complete(id: first.id)
        XCTAssertTrue(try store.read().records.allSatisfy { !$0.completed })
        _ = try store.reset()
        let second = try store.create(title: "Send invoice", owner: "Personal").records[0]
        XCTAssertNotEqual(first.id, second.id)
        _ = try store.complete(id: second.id)
        XCTAssertEqual(try TaskDiskStore(url: store.url).read().records[0].completed, true)
    }
    func testMissingEntityCannotMutateCounterOrAnySavedRecord() throws {
        _ = try seed(.correct)
        let before = try Data(contentsOf: store.url)
        XCTAssertThrowsError(try store.complete(id: UUID().uuidString))
        XCTAssertEqual(try Data(contentsOf: store.url), before)
    }
    func testMalformedPersistenceDoesNotBecomeAnEmptyValidFixture() throws {
        _ = try seed(.correct)
        try Data("invalid document".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.read())
    }
}
