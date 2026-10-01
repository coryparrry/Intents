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

    @Test func typingBurstSavesOnlyLatestDraftAfterPause() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let original = try Data(contentsOf: directory.appending(path: "suite.json"))
        for index in 0..<20 {
            store.draftSuite.name = "Typed name \(index)"
            store.scheduleSuiteSave()
        }
        #expect(store.isDraftSavePending)
        #expect(try Data(contentsOf: directory.appending(path: "suite.json")) == original)
        try await waitForSave(store)
        #expect(EvaluationStore(supportDirectory: directory).draftSuite.name == "Typed name 19")
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
        try await waitForSave(store)
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
        try await waitForSave(store)
        #expect(EvaluationStore(supportDirectory: directory).draftSuite == original)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "suite-draft.json").path))
    }

    private func waitForSave(_ store: EvaluationStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while store.isDraftSavePending && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!store.isDraftSavePending)
    }
}
