import MacIntentTesting
import Foundation
import Testing
@testable import FoundationEvals

@MainActor struct MacIntentTestingStoreTests {
    @Test func failedCatalogReplacementClearsThePreviousSelection() throws {
        let app = try fixtureApp()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let store = MacIntentTestingStore()
        store.load(appURL: app)
        #expect(store.catalog?.bundleIdentifier == "example.MacIntentFixture")
        #expect(store.selectedActionID == "EchoIntent")
        store.load(appURL: app.appending(path: "missing.app"))
        #expect(store.catalog == nil)
        #expect(store.selectedActionID.isEmpty)
        #expect(store.diagnostic != nil)
    }

    @Test func expectedValueIsExplicitAndInputsMustBeAnObject() throws {
        let app = try fixtureApp()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let store = MacIntentTestingStore()
        store.load(appURL: app)
        store.expectedValueJSON = "\"not asserted\""
        #expect(try store.testCase().expectedValueJSON == nil)
        store.checksExpectedValue = true
        #expect(try store.testCase().expectedValueJSON == "\"not asserted\"")
        store.expectedValueJSON = "{invalid"
        #expect(throws: (any Error).self) { try store.testCase() }
        store.checksExpectedValue = false
        store.inputsJSON = "[]"
        #expect(throws: (any Error).self) { try store.testCase() }
        store.inputsJSON = "{\"message\":\"hello\"}"
        #expect(try store.testCase().inputsJSON == store.inputsJSON)
    }

    @Test func missingSigningSetupPreventsDispatch() throws {
        let app = try fixtureApp()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let store = MacIntentTestingStore()
        store.load(appURL: app)
        store.start()
        #expect(!store.isRunning)
        #expect(store.result == nil)
        #expect(store.diagnostic?.contains("signing identity") == true)
    }

    private func fixtureApp() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "MacIntentStore-\(UUID())")
        let app = root.appending(path: "Fixture.app")
        let contents = app.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        let metadata = contents.appending(path: "Resources/Metadata.appintents")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "example.MacIntentFixture", "CFBundlePackageType": "APPL", "CFBundleExecutable": "Fixture"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        try Data("fixture".utf8).write(to: contents.appending(path: "MacOS/Fixture"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: contents.appending(path: "MacOS/Fixture").path)
        try Data(#"{"version":1,"actions":{"EchoIntent":{"identifier":"EchoIntent","title":{"key":"Echo"},"parameters":[]}}}"#.utf8)
            .write(to: metadata.appending(path: "extract.actionsdata"))
        return app
    }
}
