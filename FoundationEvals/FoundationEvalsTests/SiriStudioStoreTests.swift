import Foundation
import MacIntentTesting
import Testing
@testable import FoundationEvals

/// Verifies authored recovery and save admission without running Siri or reading user data.
@MainActor struct SiriStudioStoreTests {
    /// Reopens an unsaved edit with its original revision baseline and advances that revision exactly once on Save.
    @Test func recoversUnsavedEditsAndRetainsRevisionBaseline() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)
        store.load(catalog())
        store.document?.scenarios = [scenario()]
        try store.save()
        store.document?.scenarios[0].turns[0].utterance = "Edited request"
        #expect(store.hasUnsavedEdits && store.document?.scenarios[0].revision == 1)
        await store.closeAndWait()
        let recovered = makeStore(root)
        recovered.load(catalog())
        #expect(recovered.document?.scenarios[0].turns[0].utterance == "Edited request")
        #expect(recovered.hasUnsavedEdits && recovered.document?.scenarios[0].revision == 1)
        try recovered.save()
        #expect(!recovered.hasUnsavedEdits && recovered.document?.scenarios[0].revision == 2)
        try recovered.save()
        #expect(recovered.document?.scenarios[0].revision == 2)
    }

    /// Opening an exported copy saves the previous draft before adoption and recovers the imported copy after relaunch.
    @Test func replacingDocumentPreservesBothCurrentAndIncomingWork() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)
        store.load(catalog())
        store.document?.scenarios = [scenario()]
        let previous = try #require(store.document)
        let incoming = SiriStudioDocument(bundleIdentifier: catalog().bundleIdentifier,
            scenarios: [.init(name: "Imported scenario")])
        let input = root.appending(path: "incoming.json")
        try incoming.write(to: input)
        try store.openDocument(input)
        let saved = try SiriStudioDocument.read(from: root.appending(path: "Scenarios/dev.intents.store-test.json"))
        #expect(saved == previous)
        #expect(store.document == incoming && store.hasUnsavedEdits)
        let recovered = makeStore(root)
        recovered.load(catalog())
        #expect(recovered.document == incoming && recovered.hasUnsavedEdits)
    }

    /// Failed saves prevent replacement, app changes and import while retaining a recoverable draft and a visible error.
    @Test func failedSaveKeepsDraftAndBlocksImportAndReplacement() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)
        store.load(catalog())
        store.document?.scenarios = [scenario()]
        let original = store.document
        let input = root.appending(path: "incoming.json")
        try SiriStudioDocument(bundleIdentifier: catalog().bundleIdentifier).write(to: input)
        try Data("Blocked directory".utf8).write(to: root.appending(path: "Scenarios"))
        #expect(throws: (any Error).self) { try store.openDocument(input) }
        #expect(store.document == original && store.hasUnsavedEdits)
        store.importResult(root.appending(path: "old.xcresult"), developer: "/Xcode")
        #expect(!store.isBusy && store.diagnostic != nil && store.document == original)
        store.load(.init(bundleIdentifier: "other.app", appURL: URL(filePath: "/Other.app"), actions: []))
        #expect(store.catalog?.bundleIdentifier == catalog().bundleIdentifier && store.document == original)
        let recovered = makeStore(root)
        recovered.load(catalog())
        #expect(recovered.document == original)
    }

    /// Import saves and revisions edits before admitting the asynchronous evidence reader.
    @Test func importSavesTheEditedSnapshotBeforeStarting() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)
        store.load(catalog())
        store.document?.scenarios = [scenario()]
        try store.save()
        store.document?.scenarios[0].turns[0].utterance = "A changed expectation"
        // The invalid extension stops before any Xcode invocation, after store admission has frozen the saved document.
        store.importResult(root.appending(path: "invalid.txt"), developer: "/Xcode")
        #expect(store.document?.scenarios[0].revision == 2 && !store.hasUnsavedEdits)
        let saved = try SiriStudioDocument.read(from: root.appending(path: "Scenarios/dev.intents.store-test.json"))
        #expect(saved == store.document)
        await store.closeAndWait()
        #expect(!store.isBusy)
    }

    /// A failed recovery write vetoes termination without closing mutation entry points, and retry succeeds after repair.
    @Test func terminationRetriesRecoveryWithoutClosingTheEditor() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let evaluation = EvaluationStore(supportDirectory: root.appending(path: "Workspace"))
        let control = EvaluationAppControl(store: evaluation, isolatedStorage: root)
        let runtime = FoundationEvalsMCPRuntime(store: evaluation, control: control)
        let studio = control.appIntentTesting.siri
        studio.load(catalog())
        studio.document?.scenarios = [scenario()]
        let drafts = root.appending(path: "SiriStudio/Drafts")
        let retained = root.appending(path: "RetainedDrafts")
        try FileManager.default.moveItem(at: drafts, to: retained)
        try Data("Blocked directory".utf8).write(to: drafts)
        studio.document?.scenarios[0].name = "Edited before quit"
        #expect(!runtime.persistAuthoredDraftsForTermination())
        #expect(studio.diagnostic != nil && studio.hasUnsavedEdits)
        studio.document?.scenarios[0].name = "Still editable"
        try FileManager.default.removeItem(at: drafts)
        try FileManager.default.moveItem(at: retained, to: drafts)
        #expect(runtime.persistAuthoredDraftsForTermination())
        let recovered = makeStore(root.appending(path: "SiriStudio"))
        recovered.load(catalog())
        #expect(recovered.document?.scenarios[0].name == "Still editable")
    }

    /// Clean saved work does not require a recovery write, while a subsequent edit must still veto quitting.
    @Test func cleanSavedDocumentCanQuitWithUnwritableRecoveryStorage() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let evaluation = EvaluationStore(supportDirectory: root.appending(path: "Workspace"))
        let control = EvaluationAppControl(store: evaluation, isolatedStorage: root)
        let runtime = FoundationEvalsMCPRuntime(store: evaluation, control: control)
        let studio = control.appIntentTesting.siri
        studio.load(catalog())
        studio.document?.scenarios = [scenario()]
        try studio.save()
        #expect(!studio.hasUnsavedEdits)
        let drafts = root.appending(path: "SiriStudio/Drafts")
        let retained = root.appending(path: "RetainedDrafts")
        try FileManager.default.moveItem(at: drafts, to: retained)
        try Data("Blocked directory".utf8).write(to: drafts)
        #expect(runtime.persistAuthoredDraftsForTermination())
        studio.document?.scenarios[0].name = "Unsaved after clean check"
        #expect(!runtime.persistAuthoredDraftsForTermination())
        #expect(studio.hasUnsavedEdits)
    }

    /// A newly opened empty document still needs recoverable storage because no saved scenario file exists.
    @Test func newEmptyDocumentRequiresRecoveryBeforeTermination() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let studio = makeStore(root)
        studio.load(catalog())
        #expect(studio.document?.scenarios.isEmpty == true && !studio.hasUnsavedEdits)
        try Data("Blocked directory".utf8).write(to: root.appending(path: "Drafts"))
        #expect(throws: (any Error).self) { try studio.persistForTermination() }
    }

    /// Recovers launch arguments edited after Save and preserves them when switching between app drafts.
    @Test func recoversUnsavedAppLaunchArguments() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let studio = makeStore(root)
        studio.load(catalog())
        studio.document?.scenarios = [scenario()]
        try studio.save()
        studio.appLaunchArgumentsText = "-TestMode\nvalue with spaces"
        #expect(studio.hasUnsavedEdits)
        await studio.closeAndWait()
        let recovered = makeStore(root)
        recovered.load(catalog())
        #expect(recovered.appLaunchArguments == ["-TestMode", "value with spaces"])
        #expect(recovered.document?.appLaunchArguments == recovered.appLaunchArguments)
        #expect(recovered.hasUnsavedEdits)
        try recovered.save()
        #expect(!recovered.hasUnsavedEdits)
        recovered.load(nil)
        #expect(recovered.appLaunchArguments.isEmpty)
        recovered.load(catalog())
        #expect(recovered.appLaunchArguments == ["-TestMode", "value with spaces"])
    }

    /// Creates only synthetic per-test storage with no user preferences or credentials.
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "siri-store-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Uses a serial runner session without starting external commands.
    private func makeStore(_ root: URL) -> SiriStudioStore {
        SiriStudioStore(session: NativeTestSession(), root: root)
    }

    /// Provides a catalog identity without opening or executing an app.
    private func catalog() -> MacIntentCatalog {
        .init(bundleIdentifier: "dev.intents.store-test", appURL: URL(filePath: "/Fixture.app"), actions: [])
    }

    /// Creates a minimal authored scenario whose text can be edited independently of its saved revision.
    private func scenario() -> SiriStudioScenario {
        .init(name: "Fixture", turns: [.init(utterance: "Initial request",
            expectations: .init(replyContains: [.init(text: "ready")]))])
    }
}
