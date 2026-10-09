import XCTest
@testable import IntentsAutomationCore

final class AutomationSnapshotTests: XCTestCase {
    func testExcludedRegularFilesDoNotSkipTheNextProjectDirectory() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        try Data("excluded".utf8).write(to: original.appendingPathComponent(".DS_Store"))
        try Data("excluded".utf8).write(to: original.appendingPathComponent(".env"))
        let project = original.appendingPathComponent("Subject.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("project".utf8).write(to: project.appendingPathComponent("project.pbxproj"))
        let session = root.appendingPathComponent("session")
        let manifest = try AutomationSourceSnapshot.capture(source: original, sessionRoot: session)
        XCTAssertTrue(manifest.files.contains { $0.relativePath == "Subject.xcodeproj/project.pbxproj" })
        XCTAssertEqual(try Data(contentsOf: session.appendingPathComponent("source/Subject.xcodeproj/project.pbxproj")), Data("project".utf8))
    }
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("original/empty"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }
    func testSnapshotCapturesDirtyUntrackedExecutableAndSafeLinkWithoutSecrets() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        try Data("dirty checkout".utf8).write(to: original.appendingPathComponent("App.swift"))
        try Data("untracked".utf8).write(to: original.appendingPathComponent("Untracked.swift"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: original.appendingPathComponent("build.sh"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: original.appendingPathComponent("build.sh").path)
        try Data("SECRET".utf8).write(to: original.appendingPathComponent(".env"))
        try FileManager.default.createSymbolicLink(atPath: original.appendingPathComponent("Linked.swift").path, withDestinationPath: "App.swift")
        let session = URL(fileURLWithPath: root.appendingPathComponent("session").path, isDirectory: true)
        let manifest = try AutomationSourceSnapshot.capture(source: original, sessionRoot: session)
        XCTAssertEqual(manifest.files.count, 4); XCTAssertEqual(manifest.excludedPaths, [".env"])
        XCTAssertEqual(try String(contentsOf: session.appendingPathComponent("source/Linked.swift"), encoding: .utf8), "dirty checkout")
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.appendingPathComponent("source/empty").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.appendingPathComponent("source/.env").path))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: session.appendingPathComponent("source/build.sh").path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        try AutomationSourceSnapshot.verifyOriginal(manifest)
        try Data("new file".utf8).write(to: original.appendingPathComponent("Added.swift"))
        XCTAssertThrowsError(try AutomationSourceSnapshot.verifyOriginal(manifest))
        XCTAssertThrowsError(try AutomationSourceSnapshot.capture(source: original, sessionRoot: session))
    }
    func testEscapingSourceLinksAndDirectorySymlinksAreRejected() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        try Data("outside".utf8).write(to: root.appendingPathComponent("outside"))
        try FileManager.default.createSymbolicLink(atPath: original.appendingPathComponent("escape").path, withDestinationPath: "../outside")
        XCTAssertThrowsError(try AutomationSourceSnapshot.capture(source: original, sessionRoot: root.appendingPathComponent("session")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("session").path))
        XCTAssertThrowsError(try AutomationReadOnlyFile.read(root: original, relativePath: "../outside", maximumBytes: 100))
        XCTAssertThrowsError(try AutomationReadOnlyFile.read(root: original, relativePath: "..\0suffix/outside", maximumBytes: 100))
        try FileManager.default.createSymbolicLink(atPath: original.appendingPathComponent("directory").path, withDestinationPath: "..")
        XCTAssertThrowsError(try AutomationReadOnlyFile.read(root: original, relativePath: "directory/outside", maximumBytes: 100))
    }
    func testLinksAreRebasedToTheFrozenRootAndUnreadableSourcesFailClosed() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        try Data("source".utf8).write(to: original.appendingPathComponent("App.swift"))
        try FileManager.default.createSymbolicLink(atPath: original.appendingPathComponent("Linked.swift").path, withDestinationPath: "../original/App.swift")
        let session = root.appendingPathComponent("session")
        _ = try AutomationSourceSnapshot.capture(source: original, sessionRoot: session)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: session.appendingPathComponent("source/Linked.swift").path), "App.swift")
        XCTAssertEqual(try String(contentsOf: session.appendingPathComponent("source/Linked.swift"), encoding: .utf8), "source")
        let hidden = original.appendingPathComponent("unreadable")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: false)
        try Data("required build input".utf8).write(to: hidden.appendingPathComponent("Input.swift"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: hidden.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hidden.path) }
        XCTAssertThrowsError(try AutomationSourceSnapshot.capture(source: original, sessionRoot: root.appendingPathComponent("second-session")))
    }
    func testModeChangesInvalidateTheOriginalSentinel() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original"), file = original.appendingPathComponent("script")
        try Data("script".utf8).write(to: file)
        let manifest = try AutomationSourceSnapshot.capture(source: original, sessionRoot: root.appendingPathComponent("session"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        XCTAssertThrowsError(try AutomationSourceSnapshot.verifyOriginal(manifest))
    }
}
