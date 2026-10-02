import CryptoKit
import Foundation
import Testing
@testable import FoundationEvals

@MainActor
struct EditorPerformanceTests {
    @Test func contextSizeIsReusedUntilModelChangesOrRefreshes() {
        var reads = 0
        let cache = ModelContextSizeCache { _ in reads += 1; return 4096 }
        var configuration = EvaluationModelConfiguration()
        for _ in 0..<100 { #expect(cache.value(for: configuration) == 4096) }
        #expect(reads == 1)
        configuration.maximumResponseTokens = 512
        #expect(cache.value(for: configuration) == 4096)
        #expect(reads == 1)
        configuration.customizationSettings.useCase = .contentTagging
        #expect(cache.value(for: configuration) == 4096)
        #expect(reads == 2)
        cache.invalidate()
        #expect(cache.value(for: configuration) == 4096)
        #expect(reads == 3)
    }

    @Test func unavailableOnDeviceContextSizeUsesDocumentedWindow() {
        var reads = 0
        let cache = ModelContextSizeCache { _ in reads += 1; return 0 }

        #expect(cache.value(for: EvaluationModelConfiguration()) == 4_096)
        #expect(cache.value(for: EvaluationModelConfiguration()) == 4_096)
        #expect(reads == 1)
    }

    @Test func typingBurstSavesOnlyLatestDraftAfterPause() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let original = try Data(contentsOf: suiteDirectory(store, in: directory).appending(path: "suite.json"))
        for index in 0..<20 {
            store.draftSuite.name = "Typed name \(index)"
            store.scheduleSuiteSave()
        }
        #expect(store.isDraftSavePending)
        #expect(try Data(contentsOf: suiteDirectory(store, in: directory).appending(path: "suite.json")) == original)
        await waitForSave(store)
        #expect(EvaluationStore(supportDirectory: directory).draftSuite.name == "Typed name 19")
    }

    @Test func pendingSaveWaiterFollowsRescheduledDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.name = "Superseded draft"
        store.scheduleSuiteSave()

        var hasRescheduled = false
        await store.waitForScheduledSuiteSave {
            guard !hasRescheduled else { return }
            hasRescheduled = true
            store.draftSuite.name = "Latest draft"
            store.scheduleSuiteSave()
        }

        #expect(hasRescheduled)
        #expect(!store.isDraftSavePending)
        #expect(EvaluationStore(supportDirectory: directory).draftSuite.name == "Latest draft")
    }

    @Test func terminationFlushesIncompleteDraftWithoutWaitingForDebounce() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.name = "Latest unsaved edit"
        store.draftSuite.cases[0].prompt = ""
        store.scheduleSuiteSave()
        let runtime = FoundationEvalsMCPRuntime(store: store)
        await runtime.prepareForTermination()
        #expect(!store.isDraftSavePending)
        #expect(EvaluationStore(supportDirectory: directory).draftSuite == store.draftSuite)
    }

    @Test func resetCannotBeOverwrittenByPendingAutosave() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.name = "Discarded edit"
        store.scheduleSuiteSave()
        try store.resetSuite()
        await waitForSave(store)
        #expect(EvaluationStore(supportDirectory: directory).draftSuite == store.draftSuite)
        #expect(store.draftSuite.name == "Untitled Suite")
    }

    @Test func remoteReplacementCannotDiscardPendingLocalText() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let previousRevision = store.suiteRevision
        var remote = store.suite
        remote.name = "Remote edit"
        store.draftSuite.name = "Local typing"
        store.scheduleSuiteSave()
        #expect(throws: (any Error).self) {
            try store.replaceSuite(remote, expectedRevision: previousRevision, confirmDeletes: true)
        }
        #expect(store.draftSuite.name == "Local typing")
        #expect(EvaluationStore(supportDirectory: directory).draftSuite.name == "Local typing")
        #expect(store.suiteRevision != previousRevision)
    }

    @Test func revertingToCanonicalRemovesAnOlderIncompleteDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let original = store.suite
        store.draftSuite.cases[0].prompt = ""
        #expect(!store.saveSuite())
        store.draftSuite = original
        store.scheduleSuiteSave()
        await waitForSave(store)
        #expect(EvaluationStore(supportDirectory: directory).draftSuite == original)
        #expect(!FileManager.default.fileExists(atPath: suiteDirectory(store, in: directory).appending(path: "suite-draft.json").path))
    }

    @Test func blockedPendingSaveWaiterReturnsAndPreservesPendingState() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = EvaluationStore(supportDirectory: directory)

        let catalogURL = directory.appending(path: EvaluationWorkspacePersistence.catalogFilename)
        let corruptCatalog = Data("{ damaged catalog".utf8)
        try corruptCatalog.write(to: catalogURL, options: .atomic)
        let digest = SHA256.hash(data: corruptCatalog).map { String(format: "%02x", $0) }.joined()
        let backupURL = directory.appending(path: "workspace-v1-unreadable-\(digest).json")
        try Data("conflicting backup".utf8).write(to: backupURL, options: .atomic)

        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.name = "Pending while workspace is blocked"
        store.scheduleSuiteSave()

        await store.waitForScheduledSuiteSave()

        #expect(store.isDraftSavePending)
        #expect(store.draftSaveFailed)
        #expect(store.notice?.contains("could not be preserved") == true)
    }

    private func waitForSave(_ store: EvaluationStore) async {
        await store.waitForScheduledSuiteSave()
        #expect(!store.isDraftSavePending)
    }

    private func suiteDirectory(_ store: EvaluationStore, in directory: URL) -> URL {
        EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory, projectID: store.selectedProjectID, suiteID: store.selectedSuiteID
        )
    }
}
