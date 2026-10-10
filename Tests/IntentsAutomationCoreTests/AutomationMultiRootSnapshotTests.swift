import XCTest
@testable import IntentsAutomationCore

final class AutomationMultiRootSnapshotTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("root-grants-" + UUID().uuidString)
        for path in ["App", "Packages/Shared", "Unapproved"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    func testOnlyGrantedTreesAreCapturedWithoutWalkingTheirCommonAncestor() throws {
        let root = try fixture(), app = root.appendingPathComponent("App"), shared = root.appendingPathComponent("Packages/Shared")
        try Data("dirty app".utf8).write(to: app.appendingPathComponent("App.swift"))
        try Data("untracked library".utf8).write(to: shared.appendingPathComponent("Library.swift"))
        try Data("secret".utf8).write(to: shared.appendingPathComponent(".env"))
        try FileManager.default.createSymbolicLink(atPath: shared.appendingPathComponent("Link.swift").path, withDestinationPath: "Library.swift")
        let hidden = root.appendingPathComponent("Unapproved")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: hidden.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hidden.path) }
        let session = root.appendingPathComponent("session")
        let manifest = try AutomationSourceSnapshot.capture(source: app, sessionRoot: session, additionalRoots: [shared])
        XCTAssertEqual(manifest.schemaVersion, 2); XCTAssertEqual(manifest.sourceRoot, app.path); XCTAssertEqual(manifest.layoutRoot, root.path)
        XCTAssertEqual(manifest.approvedRoots, [app.path, shared.path]); XCTAssertEqual(manifest.additionalRoots, [shared.path])
        XCTAssertEqual(Set(manifest.files.map(\.relativePath)), ["App/App.swift", "Packages/Shared/Library.swift", "Packages/Shared/Link.swift"])
        XCTAssertEqual(manifest.excludedPaths, ["Packages/Shared/.env"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.appendingPathComponent("source/Unapproved").path))
        XCTAssertEqual(try String(contentsOf: session.appendingPathComponent("source/Packages/Shared/Link.swift"), encoding: .utf8), "untracked library")
        try manifest.validateCaptureLayout(); try AutomationSourceSnapshot.verifyOriginal(manifest)
        try Data("changed library".utf8).write(to: shared.appendingPathComponent("Library.swift"))
        XCTAssertThrowsError(try AutomationSourceSnapshot.verifyOriginal(manifest))
    }
    func testOverlappingDuplicateAliasAndCrossRootSymlinkGrantsAreRejected() throws {
        let root = try fixture(), app = root.appendingPathComponent("App"), shared = root.appendingPathComponent("Packages/Shared")
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "Packages/Shared")
        for extras in [[app], [shared, shared], [root], [alias], [shared, shared.appendingPathComponent("Nested")]] {
            if extras.last?.lastPathComponent == "Nested" { try FileManager.default.createDirectory(at: shared.appendingPathComponent("Nested"), withIntermediateDirectories: false) }
            let session = root.appendingPathComponent(UUID().uuidString)
            XCTAssertThrowsError(try AutomationSourceSnapshot.capture(source: app, sessionRoot: session, additionalRoots: extras))
            XCTAssertFalse(FileManager.default.fileExists(atPath: session.path))
        }
        try Data("library".utf8).write(to: shared.appendingPathComponent("Library.swift"))
        try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("Link.swift").path, withDestinationPath: "../Packages/Shared/Library.swift")
        let session = root.appendingPathComponent("linked-session")
        XCTAssertThrowsError(try AutomationSourceSnapshot.capture(source: app, sessionRoot: session, additionalRoots: [shared]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.path))
    }
    func testTamperedRootRevisionsOriginsLayoutAndInventedInputsCannotReplay() throws {
        let root = try fixture(), app = root.appendingPathComponent("App"), shared = root.appendingPathComponent("Packages/Shared")
        try Data("app".utf8).write(to: app.appendingPathComponent("App.swift"))
        try Data("library".utf8).write(to: shared.appendingPathComponent("Library.swift"))
        let manifest = try AutomationSourceSnapshot.capture(source: app, sessionRoot: root.appendingPathComponent("session"), additionalRoots: [shared])
        var changed = manifest; changed.captureLayoutRoot = "/private/tmp"
        XCTAssertThrowsError(try changed.validateCaptureLayout())
        changed = manifest; changed.files[0].inputPath = root.appendingPathComponent("Unapproved/Secret.swift").path
        XCTAssertThrowsError(try changed.validateCaptureLayout())
        changed = manifest; changed.files[0].relativePath = "Unapproved/Secret.swift"
        XCTAssertThrowsError(try changed.validateCaptureLayout())
        changed = manifest; changed.files[0].bytes = Int.max
        XCTAssertThrowsError(try changed.validateCaptureLayout())
        changed = manifest; changed.schemaVersion = 1
        XCTAssertThrowsError(try changed.validateCaptureLayout())
        changed = manifest; changed.capturedRoots = nil
        XCTAssertThrowsError(try changed.validateCaptureLayout())
        changed = manifest
        let item = try XCTUnwrap(changed.capturedRoots?.first)
        changed.capturedRoots?[0] = .init(inputPath: item.inputPath, relativePath: item.relativePath, contentDigest: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try changed.validateCaptureLayout())
        changed = manifest; changed.directories.append("Unapproved")
        XCTAssertThrowsError(try changed.validateCaptureLayout())
    }
    func testSingleRootCaptureKeepsLegacyIdentityAndAbsentGrants() throws {
        let root = try fixture(), app = root.appendingPathComponent("App")
        try Data("app".utf8).write(to: app.appendingPathComponent("App.swift"))
        let manifest = try AutomationSourceSnapshot.capture(source: app, sessionRoot: root.appendingPathComponent("session"))
        XCTAssertEqual(manifest.schemaVersion, 1); XCTAssertNil(manifest.capturedRoots); XCTAssertNil(manifest.captureLayoutRoot)
        XCTAssertEqual(manifest.layoutRoot, app.path); XCTAssertEqual(manifest.files[0].relativePath, "App.swift")
        XCTAssertEqual(try JSONDecoder().decode(AutomationSourceManifest.self, from: JSONEncoder().encode(manifest)), manifest)
        try manifest.validateCaptureLayout(); try AutomationSourceSnapshot.verifyOriginal(manifest)
    }
    func testSharedBudgetsStopLaterRootsBeforeTheirFileReadsAndOriginalReplay() throws {
        let root = try fixture(), app = root.appendingPathComponent("App"), shared = root.appendingPathComponent("Packages/Shared"), third = root.appendingPathComponent("Third")
        try FileManager.default.createDirectory(at: third, withIntermediateDirectories: false)
        try Data("app".utf8).write(to: app.appendingPathComponent("App.swift"))
        try Data("lib".utf8).write(to: shared.appendingPathComponent("Library.swift"))
        try Data("third".utf8).write(to: third.appendingPathComponent("Third.swift"))
        let manifest = try AutomationSourceSnapshot.capture(source: app, sessionRoot: root.appendingPathComponent("complete"), additionalRoots: [shared, third])
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: third.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: third.path) }
        func budgetFailure(_ operation: () throws -> Void) {
            do { try operation(); XCTFail("Combined budget was not enforced") }
            catch AutomationContractError.invalidPlan(let text) { XCTAssertTrue(text.contains("shared entry/byte budget")) }
            catch { XCTFail("Reached a later unreadable root instead of the budget fence: \(error)") }
        }
        let session = root.appendingPathComponent("bounded")
        budgetFailure { _ = try AutomationSourceSnapshot.capture(source: app, sessionRoot: session, additionalRoots: [shared, third], limits: .init(entries: 100, bytes: 5)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.path))
        budgetFailure { try AutomationSourceSnapshot.verifyOriginal(manifest, limits: .init(entries: 100, bytes: 5)) }
        budgetFailure { _ = try AutomationSourceSnapshot.capture(source: app, sessionRoot: session, additionalRoots: [shared, third], limits: .init(entries: 1, bytes: 100)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.path))
    }

    func testKnownCredentialFolderCannotBeAddedAsACaptureRoot() throws {
        let root = try fixture(), app = root.appendingPathComponent("App"), secret = root.appendingPathComponent(".aws")
        try FileManager.default.createDirectory(at: secret, withIntermediateDirectories: false)
        try Data("authored placeholder".utf8).write(to: secret.appendingPathComponent("credentials"))
        let session = root.appendingPathComponent("session")
        XCTAssertThrowsError(try AutomationSourceSnapshot.capture(source: app, sessionRoot: session, additionalRoots: [secret]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.path))
    }

}
