import XCTest
@testable import IntentsAutomationCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class AutomationProductTests: XCTestCase, @unchecked Sendable {
    func testProductManifestMatchesPythonUnicodeGoldenAndDetectsChangedResource() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // Use explicit decomposed path bytes; Foundation creates this on the qualification volume.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cafe\u{0301}"), withIntermediateDirectories: true)
        for (name, data) in ["a.txt": Data("one".utf8), "cafe\u{0301}/💫.txt": Data("two".utf8), "zero": Data()] {
            try data.write(to: root.appendingPathComponent(name))
        }
        XCTAssertEqual(try AutomationProductDigest.compute(bundle: root), "427919f7ee33230a0ac53d7479fb8969180ae03abc1de1e44eabfe3c7e285267")
        try Data("changed".utf8).write(to: root.appendingPathComponent("a.txt"))
        XCTAssertNotEqual(try AutomationProductDigest.compute(bundle: root), "427919f7ee33230a0ac53d7479fb8969180ae03abc1de1e44eabfe3c7e285267")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("a.txt"))
        XCTAssertThrowsError(try AutomationProductDigest.compute(bundle: root))
        try FileManager.default.removeItem(at: root.appendingPathComponent("link"))
        XCTAssertEqual(mkfifo(root.appendingPathComponent("pipe").path, 0o600), 0)
        XCTAssertThrowsError(try AutomationProductDigest.compute(bundle: root))
    }
    func testAtomicSwapOfAnAlreadyHashedFileCannotReturnTheFrozenManifest() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("frozen".utf8).write(to: root.appendingPathComponent("first.txt"))
        try Data("other".utf8).write(to: root.appendingPathComponent("second.txt"))
        var earlier: String?
        XCTAssertThrowsError(try AutomationProductDigest.manifestData(bundle: root, fileHashed: { name in
            if let earlier { try Data("replacement".utf8).write(to: root.appendingPathComponent(earlier), options: .atomic) }
            else { earlier = name }
        }))
    }
    func testActualFrozenProductMatchesRecordedEngineeringDigestWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["INTENTS_AUTOMATION_SUBJECT_BUNDLE"] else { throw XCTSkip("Frozen subject is an explicit integration input") }
        XCTAssertEqual(try AutomationProductDigest.compute(bundle: URL(fileURLWithPath: path)), "6311e6b95db95e606946f48eedb05a2740824a37c7d8004e9b82e8cd8ed3b2f4")
    }
}
