import CryptoKit
import Foundation
import Testing
@testable import FoundationEvals

@MainActor
struct EvaluationWorkspaceReplacementSafetyTests {
    @Test(arguments: ["state", "judgeConnections"], [false, true])
    func failedArchiveBlocksReplacementAndAllowsRetryAfterRepair(kind: String, damageBeforeOpen: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = EvaluationStore(supportDirectory: directory)
        original.draftSuite.scoringMode = .exactMatch
        original.draftSuite.cases = [EvaluationCase(name: "Sample", prompt: "ready", expected: "READY")]
        #expect(original.saveSuite())
        let suiteDirectory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory, projectID: original.selectedProjectID, suiteID: original.selectedSuiteID
        )
        let url = kind == "state" ? suiteDirectory.appending(path: "state.json")
            : directory.appending(path: "judge-connections.json")
        let prefix = kind == "state" ? "state-unreadable" : "judge-connections-unreadable"
        let bytes = Data("{ recoverable but malformed \(kind)".utf8)
        try bytes.write(to: url, options: .atomic)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let archive = url.deletingLastPathComponent().appending(path: "\(prefix)-\(digest).json")
        let unrelated = Data("Existing unrelated archive".utf8)
        try unrelated.write(to: archive)
        var store = damageBeforeOpen ? EvaluationStore(supportDirectory: directory) : original
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Local judge", kind: .localCompatible,
            baseURL: "http://127.0.0.1:1234/v1", modelID: "fixture"
        )
        let save = {
            if kind == "state" {
                _ = try store.createInstructionExperiment(name: "Retry", candidateInstructions: "Return READY")
            } else {
                try store.saveJudgeConnection(connection, apiKey: nil)
            }
        }

        #expect(throws: EvaluationStoreError.self) { try save() }
        #expect(store.suiteLocalState.experiments.isEmpty)
        #expect(store.judgeConnections.isEmpty)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try Data(contentsOf: archive) == unrelated)

        try FileManager.default.removeItem(at: archive)
        if kind == "state", damageBeforeOpen {
            await store.closeAndWait()
            store = EvaluationStore(supportDirectory: directory)
        }
        try save()
        #expect(try Data(contentsOf: archive) == bytes)
        if kind == "state" {
            let saved = try CanonicalJSON.decode(EvaluationSuiteLocalState.self, from: Data(contentsOf: url))
            #expect(saved.experiments.count == 1)
            #expect(saved.experiments.map(\.id) == store.suiteLocalState.experiments.map(\.id))
        } else {
            let saved = try CanonicalJSON.decode([EvaluationJudgeConnection].self, from: Data(contentsOf: url))
            #expect(saved.map(\.id) == [connection.id])
            #expect(store.judgeConnections.map(\.id) == [connection.id])
        }
        await store.closeAndWait()
        #expect(try Data(contentsOf: archive) == bytes)
    }
}
