import CryptoKit
import Foundation
import Testing
@testable import FoundationEvals

@MainActor
struct EvaluationWorkspaceDuplicationDraftTests {
    @Test(arguments: [false, true], ["canonical", "pending", "invalid", "inactive"])
    func duplicationPreservesCanonicalAndVisibleDraft(project: Bool, state: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.name = "Source"
        store.draftSuite.instructions = "Canonical instructions"
        store.draftSuite.scoringMode = .exactMatch
        store.draftSuite.cases = [.init(name: "Original", prompt: "Canonical prompt", expected: "RESULT")]
        try #require(store.saveSuite())
        let sourceProjectID = store.selectedProjectID
        let sourceSuiteID = store.selectedSuiteID
        let sourceDirectory = suiteDirectory(directory, projectID: sourceProjectID, suiteID: sourceSuiteID)
        let canonical = store.suite
        let sourceCanonicalBytes = try Data(contentsOf: sourceDirectory.appending(path: "suite.json"))
        let pendingPrompt = "A visible edit that has not reached its scheduled save"
        let attachmentData = Data("draft-only attachment bytes".utf8)
        var draftAttachment: EvaluationAttachment?
        if state == "pending" {
            store.editPrompt(pendingPrompt, for: canonical.cases[0].id)
            #expect(store.isDraftSavePending)
            #expect(store.draftSuite.cases[0].prompt == canonical.cases[0].prompt)
            #expect(store.promptText(for: canonical.cases[0].id) == pendingPrompt)
        } else if state == "invalid" || state == "inactive" {
            store.addCase()
            store.draftSuite.instructions = "Visible draft instructions"
            let attachment = EvaluationAttachment(
                id: UUID(), name: "draft.png", kind: .image, text: nil,
                storedFilename: "draft-only.png", byteCount: attachmentData.count,
                sha256: SHA256.hash(data: attachmentData).map { String(format: "%02x", $0) }.joined()
            )
            draftAttachment = attachment
            try attachmentData.write(to: sourceDirectory.appending(path: "Attachments/draft-only.png"))
            store.draftSuite.attachments.append(attachment)
            #expect(!store.saveSuite())
            #expect(!store.draftSaveFailed)
            #expect(store.suite == canonical)
        }
        var expectedDraft = store.draftSuite
        if state == "pending" { expectedDraft.cases[0].prompt = pendingPrompt }
        if state == "inactive" {
            if project { _ = try store.createProject(name: "Other project") }
            else { _ = try store.createSuite(name: "Other suite") }
        }
        let sourceDraftURL = sourceDirectory.appending(path: "suite-draft.json")
        let sourceDraftBytes = FileManager.default.fileExists(atPath: sourceDraftURL.path)
            ? try Data(contentsOf: sourceDraftURL) : nil
        let selectedProjectBefore = store.selectedProjectID
        let selectedSuiteBefore = store.selectedSuiteID
        let copiedProjectID: UUID
        let copiedSuiteID: UUID
        if project {
            copiedProjectID = try store.duplicateProject(id: sourceProjectID)
            let copiedProject = try #require(store.projects.first { $0.id == copiedProjectID })
            #expect(copiedProject.suites.count == 1)
            copiedSuiteID = try #require(copiedProject.suites.first?.id)
        } else {
            copiedProjectID = sourceProjectID
            copiedSuiteID = try store.duplicateSuite(id: sourceSuiteID)
        }
        #expect(copiedSuiteID != sourceSuiteID)
        #expect(store.selectedProjectID == selectedProjectBefore)
        #expect(store.selectedSuiteID == selectedSuiteBefore)
        if state == "pending" {
            #expect(store.promptText(for: canonical.cases[0].id) == pendingPrompt)
        }
        if let sourceDraftBytes {
            #expect(try Data(contentsOf: sourceDraftURL) == sourceDraftBytes)
            #expect(try Data(contentsOf: sourceDirectory.appending(path: "suite.json")) == sourceCanonicalBytes)
        }
        let copiedDirectory = suiteDirectory(directory, projectID: copiedProjectID, suiteID: copiedSuiteID)
        let copiedCanonical = try CanonicalJSON.decode(
            EvaluationSuite.self, from: Data(contentsOf: copiedDirectory.appending(path: "suite.json"))
        )
        #expect(copiedCanonical.id == copiedSuiteID)
        #expect(store.validationIssue(for: copiedCanonical, includeModelReadiness: false) == nil)
        if state != "pending" {
            var expectedCanonical = canonical
            expectedCanonical.id = copiedSuiteID
            expectedCanonical.name = copiedCanonical.name
            #expect(copiedCanonical == expectedCanonical)
        }
        expectedDraft.id = copiedSuiteID
        expectedDraft.name = copiedCanonical.name
        let copiedDraftURL = copiedDirectory.appending(path: "suite-draft.json")
        if state == "invalid" || state == "inactive" {
            #expect(FileManager.default.fileExists(atPath: copiedDraftURL.path))
        }
        if FileManager.default.fileExists(atPath: copiedDraftURL.path) {
            let copiedDraft = try CanonicalJSON.decode(DraftRecord.self, from: Data(contentsOf: copiedDraftURL))
            #expect(copiedDraft.suite == expectedDraft)
            #expect(copiedDraft.canonicalRevision == (try EvaluationStore.revision(for: copiedCanonical)))
        }
        if let draftAttachment, let filename = draftAttachment.storedFilename {
            let copiedAttachment = copiedDirectory.appending(path: "Attachments/\(filename)")
            #expect(FileManager.default.fileExists(atPath: copiedAttachment.path))
            if FileManager.default.fileExists(atPath: copiedAttachment.path) {
                #expect(try Data(contentsOf: copiedAttachment) == attachmentData)
            }
            #expect(try Data(contentsOf: sourceDirectory.appending(path: "Attachments/\(filename)")) == attachmentData)
        }
        await store.closeAndWait()

        let reloaded = EvaluationStore(supportDirectory: directory)
        try reloaded.switchProject(id: copiedProjectID)
        try reloaded.switchSuite(id: copiedSuiteID)
        #expect(reloaded.suite == copiedCanonical)
        #expect(reloaded.draftSuite == expectedDraft)
        if state == "invalid" || state == "inactive" {
            #expect(reloaded.validationIssue(for: reloaded.draftSuite, includeModelReadiness: false) != nil)
            #expect(reloaded.validationIssue(for: reloaded.suite, includeModelReadiness: false) == nil)
        }
        await reloaded.closeAndWait()
    }

    @Test(arguments: [false, true], ["unreadable", "stale", "foreign", "missingAttachment"])
    func invalidInactiveDraftRejectsDuplicationWithoutChangingSource(project: Bool, defect: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let sourceProjectID = store.selectedProjectID
        let sourceSuiteID = store.selectedSuiteID
        let sourceDirectory = suiteDirectory(directory, projectID: sourceProjectID, suiteID: sourceSuiteID)
        store.addCase()
        if defect == "missingAttachment" {
            store.draftSuite.attachments.append(.init(
                id: UUID(), name: "missing.png", kind: .image, text: nil,
                storedFilename: "missing.png", byteCount: 9, sha256: String(repeating: "0", count: 64)
            ))
            #expect(!store.saveSuite())
        }
        _ = try store.createSuite(name: "Other suite")
        let draftURL = sourceDirectory.appending(path: "suite-draft.json")
        if defect == "unreadable" {
            try Data("{ interrupted draft".utf8).write(to: draftURL)
        } else if defect == "stale" || defect == "foreign" {
            var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: draftURL)) as? [String: Any])
            if defect == "stale" {
                document["canonicalRevision"] = "different-canonical-revision"
            } else {
                var suite = try #require(document["suite"] as? [String: Any])
                suite["id"] = UUID().uuidString
                document["suite"] = suite
            }
            try JSONSerialization.data(withJSONObject: document, options: .sortedKeys).write(to: draftURL)
        }
        let filesBefore = try fileBytes(in: sourceDirectory)
        let projectsBefore = store.projects.map(\.id)
        let suitesBefore = store.suiteRecords.map(\.id)
        let catalogURL = directory.appending(path: EvaluationWorkspacePersistence.catalogFilename)
        let catalogBefore = try Data(contentsOf: catalogURL)
        let projectsDirectory = directory.appending(path: "Projects")
        let suitesDirectory = sourceDirectory.deletingLastPathComponent()
        let projectDirectoriesBefore = try children(of: projectsDirectory)
        let suiteDirectoriesBefore = try children(of: suitesDirectory)

        #expect(throws: EvaluationStoreError.self) {
            if project { _ = try store.duplicateProject(id: sourceProjectID) }
            else { _ = try store.duplicateSuite(id: sourceSuiteID) }
        }

        #expect(store.projects.map(\.id) == projectsBefore)
        #expect(store.suiteRecords.map(\.id) == suitesBefore)
        #expect(try Data(contentsOf: catalogURL) == catalogBefore)
        #expect(try fileBytes(in: sourceDirectory) == filesBefore)
        #expect(try children(of: projectsDirectory) == projectDirectoriesBefore)
        #expect(try children(of: suitesDirectory) == suiteDirectoriesBefore)
        await store.closeAndWait()
    }

    private func children(of directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    private func fileBytes(in directory: URL) throws -> [String: Data] {
        let enumerator = try #require(FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]
        ))
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(url.path.dropFirst(directory.path.count))] = try Data(contentsOf: url)
            }
        }
        return result
    }

    private func suiteDirectory(_ root: URL, projectID: UUID, suiteID: UUID) -> URL {
        EvaluationWorkspacePersistence.suiteDirectory(supportDirectory: root, projectID: projectID, suiteID: suiteID)
    }

    private struct DraftRecord: Decodable {
        let canonicalRevision: String
        let suite: EvaluationSuite
    }
}
