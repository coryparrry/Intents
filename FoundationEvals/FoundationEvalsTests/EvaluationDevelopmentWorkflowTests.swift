import Foundation
import Testing
@testable import FoundationEvals

struct EvaluationDevelopmentWorkflowTests {
    @Test func legacyBootstrapCopiesWithoutRemovingOriginals() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = EvaluationSuite()
        try CanonicalJSON.data(for: suite).write(to: directory.appending(path: "suite.json"))
        try Data("draft-marker".utf8).write(to: directory.appending(path: "suite-draft.json"))
        try FileManager.default.createDirectory(at: directory.appending(path: "Attachments"), withIntermediateDirectories: true)
        try Data("private".utf8).write(to: directory.appending(path: "Attachments/reference.txt"))
        try FileManager.default.createDirectory(at: directory.appending(path: "Runs"), withIntermediateDirectories: true)
        try Data("run-marker".utf8).write(to: directory.appending(path: "Runs/run.json"))

        let bootstrap = try EvaluationWorkspacePersistence.bootstrap(in: directory, legacySuite: suite)
        let target = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory,
            projectID: bootstrap.catalog.selectedProjectID,
            suiteID: suite.id
        )

        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "suite.json").path))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "suite-draft.json").path))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "Attachments/reference.txt").path))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "Runs/run.json").path))
        #expect(FileManager.default.fileExists(atPath: target.appending(path: "suite.json").path))
        #expect(FileManager.default.fileExists(atPath: target.appending(path: "suite-draft.json").path))
        #expect(FileManager.default.fileExists(atPath: target.appending(path: "Attachments/reference.txt").path))
        #expect(FileManager.default.fileExists(atPath: target.appending(path: "Runs/run.json").path))
        #expect(bootstrap.notice?.contains("left unchanged") == true)
    }

    @MainActor
    @Test func projectsAndSuitesKeepIndependentDraftsAndStableIDs() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let originalProject = store.selectedProjectID
        let originalSuite = store.selectedSuiteID
        store.draftSuite.name = "Original suite"
        #expect(store.saveSuite())

        let secondSuite = try store.createSuite(name: "Second suite")
        store.draftSuite.instructions = "Second-only instructions"
        #expect(store.saveSuite())
        try store.switchSuite(id: originalSuite)
        #expect(store.draftSuite.name == "Original suite")
        #expect(store.draftSuite.instructions != "Second-only instructions")
        try store.switchSuite(id: secondSuite)
        #expect(store.draftSuite.instructions == "Second-only instructions")

        let secondProject = try store.createProject(name: "Second project", starter: .groundedAnswers)
        #expect(store.selectedProjectID == secondProject)
        #expect(store.selectedProjectID != originalProject)
        #expect(store.draftSuite.cases.count >= 3)
        try store.switchProject(id: originalProject)
        #expect(store.selectedSuiteID == secondSuite)

        let reloaded = EvaluationStore(supportDirectory: directory)
        #expect(reloaded.projects.map(\.id).contains(originalProject))
        #expect(reloaded.projects.map(\.id).contains(secondProject))
        #expect(reloaded.selectedProjectID == originalProject)
        #expect(reloaded.selectedSuiteID == secondSuite)
    }

    @MainActor
    @Test func failedWorkspaceSwitchRestoresTheOriginalSuiteAndSelection() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let originalProject = store.selectedProjectID
        let originalSuite = store.selectedSuiteID
        let originalName = store.suite.name
        let brokenSuite = try store.createSuite(name: "Broken target")
        try store.switchSuite(id: originalSuite)
        let brokenDirectory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory, projectID: originalProject, suiteID: brokenSuite
        )
        try FileManager.default.removeItem(at: brokenDirectory.appending(path: "suite.json"))

        #expect(throws: EvaluationWorkspaceError.self) {
            try store.switchSuite(id: brokenSuite)
        }
        #expect(store.selectedProjectID == originalProject)
        #expect(store.selectedSuiteID == originalSuite)
        #expect(store.suite.id == originalSuite)
        #expect(store.suite.name == originalName)

        store.draftSuite.name = "Original remains writable"
        #expect(store.saveSuite())
        #expect(!FileManager.default.fileExists(atPath: brokenDirectory.appending(path: "suite.json").path))
    }

    @MainActor
    @Test func failedArchiveProjectSwitchLeavesTheCurrentProjectActive() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let originalProject = store.selectedProjectID
        let originalSuite = store.selectedSuiteID
        let replacementProject = try store.createProject(name: "Broken replacement")
        let replacementSuite = store.selectedSuiteID
        try store.switchProject(id: originalProject)
        let replacementDirectory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory,
            projectID: replacementProject,
            suiteID: replacementSuite
        )
        try FileManager.default.removeItem(at: replacementDirectory.appending(path: "suite.json"))

        #expect(throws: EvaluationWorkspaceError.self) {
            try store.archiveProject(id: originalProject)
        }
        #expect(store.selectedProjectID == originalProject)
        #expect(store.selectedSuiteID == originalSuite)
        #expect(store.projects.first(where: { $0.id == originalProject })?.isArchived == false)
    }

    @MainActor
    @Test func selectedArchivesSwitchAndPersistWithOneCatalogCommit() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let originalProject = store.selectedProjectID
        let originalSuite = store.selectedSuiteID
        let replacementSuite = try store.createSuite(name: "Suite replacement")
        try store.switchSuite(id: originalSuite)

        try store.archiveSuite(id: originalSuite)
        #expect(store.selectedSuiteID == replacementSuite)
        #expect(store.suiteRecords.first(where: { $0.id == originalSuite })?.isArchived == true)

        let replacementProject = try store.createProject(name: "Project replacement")
        try store.switchProject(id: originalProject)
        try store.archiveProject(id: originalProject)
        #expect(store.selectedProjectID == replacementProject)
        #expect(store.projects.first(where: { $0.id == originalProject })?.isArchived == true)

        let reloaded = EvaluationStore(supportDirectory: directory)
        #expect(reloaded.selectedProjectID == replacementProject)
        #expect(reloaded.projects.first(where: { $0.id == originalProject })?.isArchived == true)
    }

    @MainActor
    @Test func archivingAnUnknownSuiteFailsWithoutPersisting() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        _ = try store.createSuite(name: "Keep")
        let workspaceBeforeArchive = store.workspace
        let catalogURL = directory.appending(path: EvaluationWorkspacePersistence.catalogFilename)
        let catalogBeforeArchive = try Data(contentsOf: catalogURL)

        #expect(throws: EvaluationWorkspaceError.self) {
            try store.archiveSuite(id: UUID())
        }

        #expect(store.workspace == workspaceBeforeArchive)
        #expect(try Data(contentsOf: catalogURL) == catalogBeforeArchive)
    }

    @MainActor
    @Test func failedArchiveSuiteSwitchLeavesTheCurrentSuiteActive() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let originalSuite = store.selectedSuiteID
        let replacementSuite = try store.createSuite(name: "Broken replacement")
        try store.switchSuite(id: originalSuite)
        let replacementDirectory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory,
            projectID: store.selectedProjectID,
            suiteID: replacementSuite
        )
        try FileManager.default.removeItem(at: replacementDirectory.appending(path: "suite.json"))

        #expect(throws: EvaluationWorkspaceError.self) {
            try store.archiveSuite(id: originalSuite)
        }
        #expect(store.selectedSuiteID == originalSuite)
        #expect(store.suiteRecords.first(where: { $0.id == originalSuite })?.isArchived == false)
    }

    @Test func csvAndJSONLinesImportMapPreviewAndRejectBadRows() throws {
        let csv = Data("title,input,want\nBlue,Why blue?,Rayleigh\nQuoted,\"a,b\",ok\n".utf8)
        let mapping = EvaluationCaseImportMapping(
            nameColumn: "title", promptColumn: "input", expectedColumn: "want"
        )
        let preview = try EvaluationCaseImporter.preview(data: csv, format: .csv, mapping: mapping)
        #expect(preview.rows.count == 2)
        #expect(preview.rows[1].prompt == "a,b")
        #expect(preview.canImport)

        let jsonl = Data("{\"name\":\"One\",\"prompt\":\"P\",\"expected\":\"E\"}\n{\"name\":\"Two\",\"prompt\":2}\n".utf8)
        let invalid = try EvaluationCaseImporter.preview(
            data: jsonl,
            format: .jsonLines,
            mapping: .init(nameColumn: "name", promptColumn: "prompt", expectedColumn: "expected")
        )
        #expect(!invalid.canImport)
        #expect(invalid.issues.contains { $0.line == 2 && $0.message.contains("must be a string") })

        #expect(throws: EvaluationCaseImportError.self) {
            _ = try EvaluationCaseImporter.columns(
                in: Data(count: EvaluationStore.maximumTextFileBytes + 1), format: .csv
            )
        }
    }

    @Test func caseImportHandlesBOMAndDiscoversJSONLColumnsAcrossRows() throws {
        let csv = Data("\u{FEFF}title,input,want\nBlue,Why blue?,Rayleigh\n".utf8)
        #expect(try EvaluationCaseImporter.columns(in: csv, format: .csv) == ["title", "input", "want"])

        let jsonl = Data("\u{FEFF}{\"name\":\"One\",\"prompt\":\"P\"}\n{\"name\":\"Two\",\"prompt\":\"Q\",\"expected\":\"E\",\"tag\":\"later\"}\n".utf8)
        #expect(
            try EvaluationCaseImporter.columns(in: jsonl, format: .jsonLines)
                == ["expected", "name", "prompt", "tag"]
        )
    }

    @Test func caseImportPreviewRejectsRowsBeyondTheGlobalBound() throws {
        let jsonl = (0...EvaluationStore.maximumCases)
            .map { "{\"prompt\":\"Prompt \($0)\"}" }
            .joined(separator: "\n")

        #expect(throws: EvaluationCaseImportError.self) {
            _ = try EvaluationCaseImporter.preview(
                data: Data(jsonl.utf8),
                format: .jsonLines,
                mapping: .init(nameColumn: nil, promptColumn: "prompt", expectedColumn: nil)
            )
        }
    }

    @Test func csvImportIgnoresBlankRowsAtTheCaseLimit() throws {
        let csv = Data("prompt\nFirst\n\nSecond\n".utf8)

        let cases = try EvaluationCaseImporter.cases(
            data: csv,
            format: .csv,
            mapping: .init(nameColumn: nil, promptColumn: "prompt", expectedColumn: nil),
            maximumCases: 2
        )

        #expect(cases.map(\.prompt) == ["First", "Second"])
    }

    @Test func caseImportPreviewReportsTotalValidRowsBeyondTheDisplayedLimit() throws {
        let csv = Data(
            (["prompt"] + (1...50).map { "Prompt \($0)" }).joined(separator: "\n").utf8
        )
        let preview = try EvaluationCaseImporter.preview(
            data: csv,
            format: .csv,
            mapping: .init(nameColumn: nil, promptColumn: "prompt", expectedColumn: nil),
            limit: 20
        )
        #expect(preview.rows.count == 20)
        #expect(preview.totalValidRowCount == 50)
        #expect(preview.canImport)
        let imported = try EvaluationCaseImporter.cases(
            data: csv,
            format: .csv,
            mapping: .init(nameColumn: nil, promptColumn: "prompt", expectedColumn: nil),
            maximumCases: 10
        )
        #expect(imported.count == 10)
        #expect(imported.last?.prompt == "Prompt 10")
    }

    @MainActor
    @Test func importedCasesHonorPlannedSampleCapacityAndRollBackFailedSaves() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.scoringMode = .review
        store.draftSuite.repetitions = 5
        #expect(store.saveSuite())
        #expect(store.remainingCaseImportCapacity == 19)

        let tooMany = (0..<20).map { EvaluationCase(name: "Extra \($0)", prompt: "Prompt \($0)", expected: "") }
        #expect(throws: EvaluationCaseImportError.self) {
            try store.appendImportedCases(tooMany)
        }
        #expect(store.draftSuite.cases.count == 1)

        try store.appendImportedCases(Array(tooMany.prefix(19)))
        #expect(store.suite.cases.count == 20)
        #expect(store.plannedSampleCount == 100)

        let rollbackDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rollbackDirectory) }
        let rollbackStore = EvaluationStore(supportDirectory: rollbackDirectory)
        rollbackStore.draftSuite.scoringMode = .review
        #expect(rollbackStore.saveSuite())
        let originalCount = rollbackStore.draftSuite.cases.count
        #expect(throws: EvaluationStoreError.self) {
            try rollbackStore.appendImportedCases([
                EvaluationCase(
                    name: "Invalid import",
                    prompt: String(repeating: "x", count: EvaluationStore.maximumFieldCharacters + 1),
                    expected: ""
                )
            ])
        }
        #expect(rollbackStore.draftSuite.cases.count == originalCount)
        #expect(!rollbackStore.draftSuite.cases.contains { $0.name == "Invalid import" })
        let reloadedRollbackStore = EvaluationStore(supportDirectory: rollbackDirectory)
        #expect(reloadedRollbackStore.draftSuite.cases.count == originalCount)
        #expect(!reloadedRollbackStore.draftSuite.cases.contains { $0.name == "Invalid import" })
    }

    @MainActor
    @Test func duplicateProjectFailsWhenAnActiveSuiteCannotBeRead() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let originalProject = store.selectedProjectID
        let readable = try store.createSuite(name: "Readable")
        let broken = try store.createSuite(name: "Broken")
        try store.switchSuite(id: readable)
        let brokenDirectory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory, projectID: originalProject, suiteID: broken
        )
        try FileManager.default.removeItem(at: brokenDirectory.appending(path: "suite.json"))
        let projectsDirectory = directory.appending(path: "Projects", directoryHint: .isDirectory)
        let directoriesBeforeDuplication = Set(
            try FileManager.default.contentsOfDirectory(
                at: projectsDirectory,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent)
        )

        #expect(throws: EvaluationWorkspaceError.self) {
            _ = try store.duplicateProject(id: originalProject)
        }
        #expect(store.projects.filter { $0.name.contains("copy") }.isEmpty)
        #expect(
            Set(
                try FileManager.default.contentsOfDirectory(
                    at: projectsDirectory,
                    includingPropertiesForKeys: nil
                ).map(\.lastPathComponent)
            ) == directoriesBeforeDuplication
        )
        let reloaded = EvaluationStore(supportDirectory: directory)
        #expect(reloaded.projects.filter { $0.name.contains("copy") }.isEmpty)
    }

    @MainActor
    @Test func duplicateSuiteRemovesStagedFilesWhenAnAttachmentIsMissing() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let sourceSuiteID = store.selectedSuiteID
        store.draftSuite.attachments.append(EvaluationAttachment(
            id: UUID(),
            name: "reference.txt",
            kind: .image,
            text: nil,
            storedFilename: "missing-reference.png",
            byteCount: 9,
            sha256: String(repeating: "0", count: 64)
        ))
        #expect(store.saveSuite())
        let sourceDirectory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory,
            projectID: store.selectedProjectID,
            suiteID: sourceSuiteID
        )
        let suitesDirectory = sourceDirectory.deletingLastPathComponent()
        let directoriesBeforeDuplication = Set(
            try FileManager.default.contentsOfDirectory(
                at: suitesDirectory,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent)
        )

        #expect(throws: EvaluationStoreError.self) {
            _ = try store.duplicateSuite(id: sourceSuiteID)
        }

        #expect(store.suiteRecords.map(\.id) == [sourceSuiteID])
        #expect(
            Set(
                try FileManager.default.contentsOfDirectory(
                    at: suitesDirectory,
                    includingPropertiesForKeys: nil
                ).map(\.lastPathComponent)
            ) == directoriesBeforeDuplication
        )
    }

    @MainActor
    @Test func duplicationRejectsSuiteDataOwnedByAnotherRecord() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let projectID = store.selectedProjectID
        let suiteID = store.selectedSuiteID
        var foreignSuite = store.suite
        foreignSuite.id = UUID()
        let projectsDirectory = directory.appending(path: "Projects", directoryHint: .isDirectory)
        let suitesDirectory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory,
            projectID: projectID,
            suiteID: suiteID
        ).deletingLastPathComponent()
        try CanonicalJSON.data(for: foreignSuite).write(
            to: suitesDirectory.appending(path: "\(suiteID.uuidString)/suite.json"),
            options: .atomic
        )
        let projectDirectoriesBefore = Set(
            try FileManager.default.contentsOfDirectory(
                at: projectsDirectory,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent)
        )
        let suiteDirectoriesBefore = Set(
            try FileManager.default.contentsOfDirectory(
                at: suitesDirectory,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent)
        )

        #expect(throws: EvaluationWorkspaceError.self) {
            _ = try store.duplicateSuite(id: suiteID)
        }
        #expect(throws: EvaluationWorkspaceError.self) {
            _ = try store.duplicateProject(id: projectID)
        }

        #expect(store.suiteRecords.map(\.id) == [suiteID])
        #expect(store.projects.count == 1)
        #expect(
            Set(
                try FileManager.default.contentsOfDirectory(
                    at: projectsDirectory,
                    includingPropertiesForKeys: nil
                ).map(\.lastPathComponent)
            ) == projectDirectoriesBefore
        )
        #expect(
            Set(
                try FileManager.default.contentsOfDirectory(
                    at: suitesDirectory,
                    includingPropertiesForKeys: nil
                ).map(\.lastPathComponent)
            ) == suiteDirectoriesBefore
        )
    }

    @MainActor
    @Test func failedBaselineApprovalDoesNotPublishInMemory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.scoringMode = .exactMatch
        #expect(store.saveSuite())
        var run = makeRun(cases: store.suite.cases, statuses: [[.passed]])
        run.suiteID = store.suite.id
        run.scoringMode = .exactMatch
        run.suiteRevision = store.suiteRevision
        store.runs = [run]
        let stateURL = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory, projectID: store.selectedProjectID, suiteID: store.selectedSuiteID
        ).appending(path: "state.json")
        if FileManager.default.fileExists(atPath: stateURL.path) {
            try FileManager.default.removeItem(at: stateURL)
        }
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)

        #expect(throws: (any Error).self) {
            try store.approveBaseline(runID: run.id, assessmentID: nil)
        }
        #expect(store.suiteLocalState.baselineApprovals.isEmpty)
        #expect(store.activeBaselineApproval == nil)
    }

    @MainActor
    @Test func failedCandidateAdoptionDoesNotPersistTheDecision() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let originalInstructions = store.suite.instructions
        let experimentID = try store.createInstructionExperiment(
            name: "Candidate",
            candidateInstructions: String(
                repeating: "x",
                count: EvaluationStore.maximumFieldCharacters + 1
            )
        )
        let suiteDirectory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory,
            projectID: store.selectedProjectID,
            suiteID: store.selectedSuiteID
        )
        let stateURL = suiteDirectory.appending(path: "state.json")
        let stateBeforeAdoption = try Data(contentsOf: stateURL)

        #expect(throws: EvaluationStoreError.self) {
            try store.decideExperiment(id: experimentID, decision: .adoptCandidate)
        }

        #expect(store.suite.instructions == originalInstructions)
        #expect(store.draftSuite.instructions == originalInstructions)
        #expect(store.suiteLocalState.experiments.first { $0.id == experimentID }?.decision == nil)
        #expect(try Data(contentsOf: stateURL) == stateBeforeAdoption)
        let reloaded = EvaluationStore(supportDirectory: directory)
        #expect(reloaded.suite.instructions == originalInstructions)
        #expect(reloaded.draftSuite.instructions == originalInstructions)
    }

    @MainActor
    @Test func failedExperimentDecisionPersistenceRollsBackCandidateAdoption() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var shouldFailStateWrites = false
        let store = EvaluationStore(
            supportDirectory: directory,
            suiteLocalStateWriter: { data, url in
                if shouldFailStateWrites {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try data.write(to: url, options: .atomic)
            }
        )
        let originalSuite = store.suite
        let experimentID = try store.createInstructionExperiment(
            name: "Candidate",
            candidateInstructions: "Replacement candidate instructions"
        )
        var previousDraft = originalSuite
        previousDraft.name = "Uncommitted draft"
        store.draftSuite = previousDraft
        let pendingPrompt = "Pending prompt edit"
        store.editPrompt(pendingPrompt, for: originalSuite.cases[0].id)
        let suiteDirectory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory,
            projectID: store.selectedProjectID,
            suiteID: store.selectedSuiteID
        )
        let stateURL = suiteDirectory.appending(path: "state.json")
        shouldFailStateWrites = true

        #expect(throws: (any Error).self) {
            try store.decideExperiment(id: experimentID, decision: .adoptCandidate)
        }

        #expect(store.suite == originalSuite)
        #expect(store.draftSuite.name == previousDraft.name)
        #expect(store.draftSuite.cases[0].prompt == pendingPrompt)
        #expect(store.promptText(for: originalSuite.cases[0].id) == pendingPrompt)
        #expect(store.isDraftSavePending)
        #expect(store.suiteLocalState.experiments.first { $0.id == experimentID }?.decision == nil)
        #expect(
            try CanonicalJSON.decode(
                EvaluationSuite.self,
                from: Data(contentsOf: suiteDirectory.appending(path: "suite.json"))
            ) == originalSuite
        )
        let persistedState = try CanonicalJSON.decode(
            EvaluationSuiteLocalState.self,
            from: Data(contentsOf: stateURL)
        )
        #expect(persistedState.experiments.first { $0.id == experimentID }?.decision == nil)
        shouldFailStateWrites = false
        #expect(store.saveSuite())
    }

    @MainActor
    @Test func starterPacksAreCompleteRunnableAndUseRelevantScoring() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        for pack in EvaluationStarterPack.allCases {
            let suite = pack.makeSuite()
            #expect(suite.cases.count >= 3)
            #expect(suite.cases.allSatisfy { !$0.name.isEmpty && !$0.prompt.isEmpty })
            #expect(!suite.criteria.isEmpty)
            #expect(store.validationIssue(for: suite, includeModelReadiness: false) == nil)
        }
        #expect(EvaluationStarterPack.structuredExtraction.makeSuite().features.outputFields.isEmpty == false)
        let structured = EvaluationStarterPack.structuredExtraction.makeSuite()
        let outputNames = Set(structured.features.outputFields.map(\.name))
        for evaluationCase in structured.cases {
            let expected = try #require(
                JSONSerialization.jsonObject(with: Data(evaluationCase.expected.utf8)) as? [String: Any]
            )
            for assertion in evaluationCase.fieldAssertions ?? [] {
                let topLevelName = String(assertion.pointer.dropFirst()).split(separator: "/").first.map(String.init)
                let field = try #require(topLevelName)
                #expect(outputNames.contains(field))
                #expect(expected[field] != nil)
            }
        }
        #expect(EvaluationStarterPack.groundedAnswers.makeSuite().cases.allSatisfy { !$0.expected.isEmpty })
        #expect(EvaluationStarterPack.conversationBehaviour.makeSuite().cases.contains { !$0.conversation.setupTurns.isEmpty })
    }

    @Test func experimentAnalysisUsesDistinctCasesNotRepeatCount() {
        let cases = (0..<4).map { EvaluationCase(name: "Case \($0)", prompt: "P", expected: "E") }
        let current = makeRun(cases: cases, statuses: [
            [.failed, .failed, .failed], [.passed, .passed, .passed],
            [.failed, .passed, .failed], [.passed, .failed, .passed]
        ])
        let candidate = makeRun(cases: cases, statuses: [
            [.passed, .passed, .passed], [.failed, .failed, .failed],
            [.failed, .passed, .failed], [.passed, .failed, .passed]
        ])
        let summary = EvaluationExperimentAnalyzer.summarize(current: current, candidate: candidate)
        #expect(summary.distinctCaseCoverage == 4)
        #expect(summary.improvedCaseIDs.count == 1)
        #expect(summary.regressedCaseIDs.count == 1)
        #expect(summary.unchangedCaseIDs.count == 2)
        #expect(summary.suggestedDecision == .inconclusive)
        #expect(EvaluationExperimentAnalyzer.balancedOrder(
            currentID: cases[0].id, candidateID: cases[1].id, caseCount: 4, repetitions: 3
        ).count == 24)
    }

    @Test func experimentAnalysisNeverAdoptsIncompleteOrErrorDominatedCandidate() {
        let cases = (0..<4).map { EvaluationCase(name: "Case \($0)", prompt: "P", expected: "E") }
        let current = makeRun(cases: cases, statuses: Array(
            repeating: [.passed, .passed, .passed, .passed, .failed], count: 4
        ))
        let candidate = makeRun(cases: cases, statuses: Array(
            repeating: [.passed, .error, .error, .error, .error], count: 4
        ))

        let errorDominated = EvaluationExperimentAnalyzer.summarize(current: current, candidate: candidate)
        #expect(errorDominated.suggestedDecision == .collectMoreEvidence)
        #expect(errorDominated.explanation.contains("error-free"))

        var missing = candidate
        missing.results.removeLast()
        let missingSummary = EvaluationExperimentAnalyzer.summarize(current: current, candidate: missing)
        #expect(missingSummary.suggestedDecision == .collectMoreEvidence)

        var unscored = candidate
        unscored.results = unscored.results.map { result in
            var result = result
            result.status = .unscored
            return result
        }
        let unscoredSummary = EvaluationExperimentAnalyzer.summarize(current: current, candidate: unscored)
        #expect(unscoredSummary.suggestedDecision == .collectMoreEvidence)
    }

    @MainActor
    @Test func experimentVariantsCarryActualRevisionsBeforeAndAfterAdoption() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.scoringMode = .exactMatch
        store.draftSuite.cases[0].expected = "READY"
        #expect(store.saveSuite())
        let sourceRevision = store.suiteRevision
        let experimentID = try store.createInstructionExperiment(
            name: "Prompt change", candidateInstructions: "Return the verified answer only."
        )
        let experiment = try #require(store.suiteLocalState.experiments.first { $0.id == experimentID })
        let candidateRevision = try #require(experiment.candidate.suiteRevision)
        #expect(experiment.current.suiteRevision == sourceRevision)
        #expect(candidateRevision != sourceRevision)

        var candidateSuite = store.suite
        candidateSuite.instructions = experiment.candidate.instructions
        var candidateRun = makeRun(cases: candidateSuite.cases, statuses: [[.passed]])
        candidateRun.suiteID = candidateSuite.id
        candidateRun.instructions = candidateSuite.instructions
        candidateRun.criteria = candidateSuite.criteria
        candidateRun.scoringMode = candidateSuite.scoringMode
        candidateRun.suiteRevision = candidateRevision
        candidateRun.suiteDefinition = EvaluationSuiteDefinition(suite: candidateSuite)

        let beforeAdoption = EvaluationReleaseCheckEvaluator.report(
            projectID: store.selectedProjectID, suite: store.suite,
            currentSuiteRevision: sourceRevision, run: candidateRun,
            baseline: nil, approvedBaseline: nil
        )
        #expect(beforeAdoption.outcome == .incompleteOrIncompatibleEvidence)
        #expect(beforeAdoption.failures.contains { $0.contains("stale") })

        try store.decideExperiment(id: experimentID, decision: .adoptCandidate)
        #expect(store.suiteRevision == candidateRevision)
        let afterAdoption = EvaluationReleaseCheckEvaluator.report(
            projectID: store.selectedProjectID, suite: store.suite,
            currentSuiteRevision: store.suiteRevision, run: candidateRun,
            baseline: nil, approvedBaseline: nil
        )
        #expect(afterAdoption.outcome == .passed)
    }

    @Test func releaseChecksFailClosedAndDistinguishRegressionFromExecution() {
        var suite = EvaluationSuite()
        suite.scoringMode = .exactMatch
        suite.releasePolicy.required = true
        suite.releasePolicy.criticalCaseIDs = [suite.cases[0].id]
        let projectID = UUID()
        var run = makeRun(cases: suite.cases, statuses: [[.passed]])
        run.suiteID = suite.id
        run.criteria = suite.criteria
        run.scoringMode = suite.scoringMode
        run.suiteRevision = "current"
        run.suiteDefinition = EvaluationSuiteDefinition(suite: suite)

        let passed = EvaluationReleaseCheckEvaluator.report(
            projectID: projectID, suite: suite, currentSuiteRevision: "current",
            run: run, baseline: nil, approvedBaseline: nil
        )
        #expect(passed.outcome == .passed)

        run.results[0].status = .failed
        let regression = EvaluationReleaseCheckEvaluator.report(
            projectID: projectID, suite: suite, currentSuiteRevision: "current",
            run: run, baseline: nil, approvedBaseline: nil
        )
        #expect(regression.outcome == .regression)

        run.results[0].errorCategory = "provider"
        let execution = EvaluationReleaseCheckEvaluator.report(
            projectID: projectID, suite: suite, currentSuiteRevision: "current",
            run: run, baseline: nil, approvedBaseline: nil
        )
        #expect(execution.outcome == .executionError)

        let stale = EvaluationReleaseCheckEvaluator.report(
            projectID: projectID, suite: suite, currentSuiteRevision: "changed",
            run: run, baseline: nil, approvedBaseline: nil
        )
        #expect(stale.outcome == .executionError)
        #expect(stale.failures.contains { $0.contains("stale") })

        suite.releasePolicy.requireApprovedBaseline = true
        run.results[0].errorCategory = nil
        run.results[0].status = .passed
        let staleApproval = EvaluationBaselineApproval(
            id: UUID(), runID: run.id, assessmentID: nil, suiteRevision: "previous",
            approvedAt: Date(), note: nil, revokedAt: nil
        )
        let staleBaseline = EvaluationReleaseCheckEvaluator.report(
            projectID: projectID, suite: suite, currentSuiteRevision: "current",
            run: run, baseline: run, approvedBaseline: staleApproval
        )
        #expect(staleBaseline.outcome == .passed)
    }

    @Test func releaseChecksUseTheSelectedAssessmentForCriticalCases() {
        var suite = EvaluationSuite()
        suite.scoringMode = .modelJudge
        suite.releasePolicy.criticalCaseIDs = [suite.cases[0].id]
        var run = makeRun(cases: suite.cases, statuses: [[.passed]])
        run.suiteID = suite.id
        run.criteria = suite.criteria
        run.suiteRevision = "current"
        run.suiteDefinition = EvaluationSuiteDefinition(suite: suite)
        let sample = run.results[0]
        let assessment = EvaluationAssessment(
            id: UUID(), runID: run.id, createdAt: Date(), origin: .reassessment,
            judge: .init(
                mode: .connection, connectionID: UUID(), connectionName: "Fixture",
                endpointKind: .customCompatible, baseURL: "https://judge.example",
                requestedModelID: "judge-v1", reportedModelID: "judge-v1",
                provider: "fixture", providerOrder: []
            ),
            promptVersion: EvaluationRunner.judgePromptVersion, rubric: suite.criteria, passingScore: 3,
            samples: [.init(
                id: UUID(), sampleID: sample.id, status: .failed, score: 2,
                rationale: "Incorrect", trace: nil, errorCategory: nil, errorMessage: nil,
                usage: nil, durationMilliseconds: 1
            )],
            totalUsage: nil, durationMilliseconds: 1,
            cost: .init(availability: .unavailable, usd: nil, explanation: "Fixture"),
            supersedesAssessmentID: nil,
            scoringContract: try? EvaluationScoringContract(suite: suite)
        )
        run.assessments = [assessment]
        run.selectedAssessmentID = assessment.id

        let report = EvaluationReleaseCheckEvaluator.report(
            projectID: UUID(), suite: suite, currentSuiteRevision: "current",
            run: run, baseline: nil, approvedBaseline: nil
        )

        #expect(report.outcome == .regression)
        #expect(report.assessmentID == assessment.id)

        var mixedRun = run
        var mixedAssessment = assessment
        var secondIdentity = assessment.judge
        secondIdentity.reportedModelID = "judge-v2"
        mixedAssessment.observedJudgeIdentities = [assessment.judge, secondIdentity]
        mixedRun.assessments = [mixedAssessment]
        let mixed = EvaluationReleaseCheckEvaluator.report(
            projectID: UUID(), suite: suite, currentSuiteRevision: "current",
            run: mixedRun, baseline: nil, approvedBaseline: nil
        )
        #expect(mixed.outcome == .incompleteOrIncompatibleEvidence)
        #expect(mixed.failures.contains { $0.contains("mixed judge") })
    }

    @Test func releaseChecksRejectMissingOrUnscoredJudgeAssessment() {
        var suite = EvaluationSuite()
        suite.scoringMode = .modelJudge
        var run = makeRun(cases: suite.cases, statuses: [[.passed]])
        run.suiteID = suite.id
        run.suiteRevision = "current"

        let missing = EvaluationReleaseCheckEvaluator.report(
            projectID: UUID(), suite: suite, currentSuiteRevision: "current",
            run: run, baseline: nil, approvedBaseline: nil
        )
        #expect(missing.outcome == .incompleteOrIncompatibleEvidence)
        #expect(missing.failures.contains { $0.contains("assessment") })
    }

    @Test func releaseChecksRejectReassessmentsAndApprovalsFromAnotherScoringContract() throws {
        var suite = EvaluationSuite()
        suite.scoringMode = .modelJudge
        suite.releasePolicy.requireApprovedBaseline = true
        let judge = fixtureJudge()
        var easierSuite = suite
        easierSuite.criteria = "The response contains any text."

        var current = makeRun(cases: suite.cases, statuses: [[.passed]])
        current.suiteID = suite.id
        current.criteria = suite.criteria
        current.suiteRevision = "current"
        current.suiteDefinition = EvaluationSuiteDefinition(suite: suite)
        let currentAssessment = try makeAssessment(
            run: current, suite: suite, status: .passed, judge: judge
        )
        current.assessments = [currentAssessment]
        current.selectedAssessmentID = currentAssessment.id

        var mismatchedCurrent = current
        let easierAssessment = try makeAssessment(
            run: mismatchedCurrent, suite: easierSuite, status: .passed, judge: judge
        )
        mismatchedCurrent.assessments = [easierAssessment]
        mismatchedCurrent.selectedAssessmentID = easierAssessment.id
        suite.releasePolicy.requireApprovedBaseline = false
        let selectedMismatch = EvaluationReleaseCheckEvaluator.report(
            projectID: UUID(), suite: suite, currentSuiteRevision: "current",
            run: mismatchedCurrent, baseline: nil, approvedBaseline: nil
        )
        #expect(selectedMismatch.outcome == .incompleteOrIncompatibleEvidence)
        #expect(selectedMismatch.failures.contains { $0.contains("selected assessment used a different") })

        suite.releasePolicy.requireApprovedBaseline = true
        var baseline = current
        baseline.id = UUID()
        baseline.results[0].id = UUID()
        let easierBaselineAssessment = try makeAssessment(
            run: baseline, suite: easierSuite, status: .passed, judge: judge
        )
        baseline.assessments = [easierBaselineAssessment]
        baseline.selectedAssessmentID = easierBaselineAssessment.id
        let approval = EvaluationBaselineApproval(
            id: UUID(), runID: baseline.id, assessmentID: easierBaselineAssessment.id,
            suiteRevision: "temporary-easier-rubric", approvedAt: Date(), note: nil,
            revokedAt: nil, scoringContract: easierBaselineAssessment.scoringContract
        )
        let approvedMismatch = EvaluationReleaseCheckEvaluator.report(
            projectID: UUID(), suite: suite, currentSuiteRevision: "current",
            run: current, baseline: baseline, approvedBaseline: approval
        )
        #expect(approvedMismatch.outcome == .incompleteOrIncompatibleEvidence)
        #expect(approvedMismatch.failures.contains { $0.contains("approved baseline uses incompatible") })
    }

    @Test func approvedBaselineRemainsComparableAcrossInstructionChangesOnly() throws {
        var baselineSuite = EvaluationSuite()
        baselineSuite.scoringMode = .exactMatch
        baselineSuite.releasePolicy.requireApprovedBaseline = true
        baselineSuite.cases[0].expected = "READY"
        baselineSuite.cases[0].conversation.setupTurns = [
            EvaluationSetupTurn(id: UUID(), prompt: "Prepare the response.")
        ]
        baselineSuite.cases[0].fieldAssertions = [
            EvaluationFieldAssertion(id: UUID(), pointer: "/ready", operation: .exists, expectedValue: "ignored")
        ]
        baselineSuite.cases.append(
            EvaluationCase(name: "Second", prompt: "Return SET", expected: "SET")
        )
        var baseline = makeRun(cases: baselineSuite.cases, statuses: [[.passed], [.passed]])
        baseline.suiteID = baselineSuite.id
        baseline.instructions = baselineSuite.instructions
        baseline.criteria = baselineSuite.criteria
        baseline.scoringMode = .exactMatch
        baseline.suiteRevision = "baseline-revision"
        baseline.suiteDefinition = EvaluationSuiteDefinition(suite: baselineSuite)
        let approval = EvaluationBaselineApproval(
            id: UUID(), runID: baseline.id, assessmentID: nil,
            suiteRevision: "baseline-revision", approvedAt: Date(), note: nil,
            revokedAt: nil, scoringContract: try EvaluationScoringContract(suite: baselineSuite)
        )

        var changedSuite = baselineSuite
        changedSuite.instructions = "New subject instructions being evaluated."
        changedSuite.cases.reverse()
        changedSuite.cases[1].name = "Renamed display label"
        changedSuite.cases[1].conversation.setupTurns[0].id = UUID()
        changedSuite.cases[1].conversation.modelHistoryProjection = .init()
        changedSuite.cases[1].fieldAssertions?[0].id = UUID()
        changedSuite.cases[1].fieldAssertions?[0].expectedValue = "also ignored"
        var current = makeRun(cases: changedSuite.cases, statuses: [[.passed], [.passed]])
        current.suiteID = changedSuite.id
        current.instructions = changedSuite.instructions
        current.criteria = changedSuite.criteria
        current.scoringMode = .exactMatch
        current.suiteRevision = "changed-instructions"
        current.suiteDefinition = EvaluationSuiteDefinition(suite: changedSuite)
        let compatible = EvaluationReleaseCheckEvaluator.report(
            projectID: UUID(), suite: changedSuite, currentSuiteRevision: "changed-instructions",
            run: current, baseline: baseline, approvedBaseline: approval
        )
        #expect(compatible.outcome == .passed)

        changedSuite.cases[1].prompt = "A genuinely different case"
        current.plannedCases = changedSuite.cases
        current.suiteDefinition = EvaluationSuiteDefinition(suite: changedSuite)
        current.suiteRevision = "changed-cases"
        let incompatible = EvaluationReleaseCheckEvaluator.report(
            projectID: UUID(), suite: changedSuite, currentSuiteRevision: "changed-cases",
            run: current, baseline: baseline, approvedBaseline: approval
        )
        #expect(incompatible.outcome == .incompleteOrIncompatibleEvidence)
        #expect(incompatible.failures.contains { $0.contains("approved baseline uses incompatible") })
    }

    @Test func modelJudgeBaselineAllowsRubricFormattingOnlyChanges() throws {
        var baselineSuite = EvaluationSuite()
        baselineSuite.criteria = "First requirement\nSecond requirement"
        baselineSuite.scoringMode = .modelJudge
        baselineSuite.releasePolicy.requireApprovedBaseline = true
        let judge = fixtureJudge()
        var baseline = makeRun(cases: baselineSuite.cases, statuses: [[.passed]])
        baseline.suiteID = baselineSuite.id
        baseline.criteria = baselineSuite.criteria
        baseline.suiteRevision = "baseline"
        baseline.suiteDefinition = EvaluationSuiteDefinition(suite: baselineSuite)
        let baselineAssessment = try makeAssessment(
            run: baseline,
            suite: baselineSuite,
            status: .passed,
            judge: judge
        )
        baseline.assessments = [baselineAssessment]
        baseline.selectedAssessmentID = baselineAssessment.id
        let approval = EvaluationBaselineApproval(
            id: UUID(),
            runID: baseline.id,
            assessmentID: baselineAssessment.id,
            suiteRevision: "baseline",
            approvedAt: Date(),
            note: nil,
            revokedAt: nil,
            scoringContract: baselineAssessment.scoringContract
        )

        var currentSuite = baselineSuite
        currentSuite.criteria = "  First requirement  \n\nSecond requirement\n"
        var current = makeRun(cases: currentSuite.cases, statuses: [[.passed]])
        current.suiteID = currentSuite.id
        current.criteria = currentSuite.criteria
        current.suiteRevision = "current"
        current.suiteDefinition = EvaluationSuiteDefinition(suite: currentSuite)
        let currentAssessment = try makeAssessment(
            run: current,
            suite: currentSuite,
            status: .passed,
            judge: judge
        )
        current.assessments = [currentAssessment]
        current.selectedAssessmentID = currentAssessment.id

        let report = EvaluationReleaseCheckEvaluator.report(
            projectID: UUID(),
            suite: currentSuite,
            currentSuiteRevision: "current",
            run: current,
            baseline: baseline,
            approvedBaseline: approval
        )

        #expect(report.outcome == .passed)
    }

    @Test func selectedAssessmentDrivesSummaryAnalysisComparisonAndReleaseReport() throws {
        var suite = EvaluationSuite()
        suite.scoringMode = .modelJudge
        suite.releasePolicy.criticalCaseIDs = [suite.cases[0].id]
        let judge = fixtureJudge()
        var run = makeRun(cases: suite.cases, statuses: [[.passed]])
        run.suiteID = suite.id
        run.criteria = suite.criteria
        run.suiteRevision = "current"
        run.suiteDefinition = EvaluationSuiteDefinition(suite: suite)
        var passedAssessment = try makeAssessment(run: run, suite: suite, status: .passed, judge: judge)
        passedAssessment.samples[0].usage = EvaluationUsage(outputTokens: 2)
        var failedAssessment = try makeAssessment(run: run, suite: suite, status: .failed, judge: judge)
        failedAssessment.samples[0].usage = EvaluationUsage(outputTokens: 7)
        run.assessments = [passedAssessment, failedAssessment]
        run.selectedAssessmentID = passedAssessment.id

        var baseline = run
        baseline.id = UUID()
        baseline.results[0].id = UUID()
        let baselineAssessment = try makeAssessment(
            run: baseline, suite: suite, status: .passed, judge: judge
        )
        baseline.assessments = [baselineAssessment]
        baseline.selectedAssessmentID = baselineAssessment.id

        #expect(run.passedCount == 1)
        #expect(EvaluationRunAnalysis(run: run).passedSampleCount == 1)
        #expect(EvaluationRunComparison(current: run, baseline: baseline).unchangedCaseCount == 1)

        run.selectedAssessmentID = failedAssessment.id
        let analysis = EvaluationRunAnalysis(run: run)
        let comparison = EvaluationRunComparison(current: run, baseline: baseline)
        let report = EvaluationReleaseCheckEvaluator.report(
            projectID: UUID(), suite: suite, currentSuiteRevision: "current",
            run: run, baseline: nil, approvedBaseline: nil
        )
        #expect(run.failedCount == 1)
        #expect(analysis.failedSampleCount == 1)
        #expect(analysis.judgeUsage.outputTokens == 7)
        #expect(comparison.regressedCaseCount == 1)
        #expect(report.outcome == .regression)
    }

    @Test func releaseChecksBindSelectedAssessmentToImmutableSubjectEvidence() throws {
        var suite = EvaluationSuite()
        suite.scoringMode = .modelJudge
        let judge = fixtureJudge()
        var run = makeRun(cases: suite.cases, statuses: [[.passed]])
        run.suiteID = suite.id
        run.criteria = suite.criteria
        run.suiteRevision = "current"
        run.suiteDefinition = EvaluationSuiteDefinition(suite: suite)
        let digest = try EvaluationSubjectEvidenceSnapshot.digest(
            instructions: suite.instructions,
            cases: suite.cases,
            attachments: []
        )
        run.subjectEvidence = .init(
            instructions: suite.instructions,
            cases: suite.cases,
            attachments: [],
            digest: digest
        )
        var assessment = try makeAssessment(
            run: run, suite: suite, status: .passed, judge: judge
        )
        assessment.subjectEvidenceDigest = nil
        run.assessments = [assessment]
        run.selectedAssessmentID = assessment.id

        var report = EvaluationReleaseCheckEvaluator.report(
            projectID: UUID(), suite: suite, currentSuiteRevision: "current",
            run: run, baseline: nil, approvedBaseline: nil
        )
        #expect(report.outcome == .incompleteOrIncompatibleEvidence)
        #expect(report.failures.contains { $0.contains("not bound") })

        run.assessments?[0].subjectEvidenceDigest = digest
        report = EvaluationReleaseCheckEvaluator.report(
            projectID: UUID(), suite: suite, currentSuiteRevision: "current",
            run: run, baseline: nil, approvedBaseline: nil
        )
        #expect(report.outcome == .passed)

        run.subjectEvidence?.digest = "tampered"
        report = EvaluationReleaseCheckEvaluator.report(
            projectID: UUID(), suite: suite, currentSuiteRevision: "current",
            run: run, baseline: nil, approvedBaseline: nil
        )
        #expect(report.outcome == .incompleteOrIncompatibleEvidence)
        #expect(report.failures.contains { $0.contains("integrity") })
    }

    @Test func releaseChecksRejectUnscoredManualReviewRuns() {
        var suite = EvaluationSuite()
        suite.scoringMode = .review
        var run = makeRun(cases: suite.cases, statuses: [[.unscored]])
        run.suiteID = suite.id
        run.scoringMode = .review
        run.suiteRevision = "current"

        let report = EvaluationReleaseCheckEvaluator.report(
            projectID: UUID(), suite: suite, currentSuiteRevision: "current",
            run: run, baseline: nil, approvedBaseline: nil
        )

        #expect(report.outcome == .incompleteOrIncompatibleEvidence)
        #expect(report.failures.contains { $0.contains("pass/fail evidence") })
    }

    @MainActor
    @Test func releasePolicyRejectsFailOpenOrInvalidThresholds() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        var suite = store.suite

        suite.releasePolicy.maximumPassRateRegression = 1.01
        #expect(store.validationIssue(for: suite, includeModelReadiness: false)?.contains("between 0 and 1") == true)
        var run = makeRun(cases: suite.cases, statuses: [[.passed]])
        run.suiteID = suite.id
        run.suiteRevision = "current"
        let invalidReport = EvaluationReleaseCheckEvaluator.report(
            projectID: UUID(), suite: suite, currentSuiteRevision: "current",
            run: run, baseline: nil, approvedBaseline: nil
        )
        #expect(invalidReport.outcome == .incompleteOrIncompatibleEvidence)
        #expect(invalidReport.failures.contains { $0.contains("release policy is invalid") })
        suite.releasePolicy.maximumPassRateRegression = 0
        suite.releasePolicy.maximumErrorCount = -1
        #expect(store.validationIssue(for: suite, includeModelReadiness: false)?.contains("error limit") == true)
        suite.releasePolicy.maximumErrorCount = 0
        suite.releasePolicy.maximumAverageLatencyMilliseconds = .infinity
        #expect(store.validationIssue(for: suite, includeModelReadiness: false)?.contains("finite") == true)
        suite.releasePolicy.maximumAverageLatencyMilliseconds = nil
        suite.releasePolicy.criticalCaseIDs = [UUID()]
        #expect(store.validationIssue(for: suite, includeModelReadiness: false)?.contains("critical release case") == true)
    }

    @Test func releaseChecksKeepTheExplicitlyApprovedBaselineAssessment() {
        var suite = EvaluationSuite()
        suite.scoringMode = .modelJudge
        suite.releasePolicy.requireApprovedBaseline = true
        let suiteID = suite.id
        let judge = EvaluationJudgeIdentity(
            mode: .connection, connectionID: UUID(), connectionName: "Fixture",
            endpointKind: .customCompatible, baseURL: "https://judge.example",
            requestedModelID: "judge-v1", reportedModelID: "judge-v1",
            provider: "fixture", providerOrder: []
        )
        func assessment(for run: EvaluationRun, status: EvaluationResultStatus) -> EvaluationAssessment {
            EvaluationAssessment(
                id: UUID(), runID: run.id, createdAt: Date(), origin: .reassessment,
                judge: judge, promptVersion: EvaluationRunner.judgePromptVersion,
                rubric: suite.criteria, passingScore: 3,
                samples: [.init(
                    id: UUID(), sampleID: run.results[0].id, status: status,
                    score: status == .passed ? 4 : 2, rationale: "Fixture", trace: nil,
                    errorCategory: nil, errorMessage: nil, usage: nil, durationMilliseconds: 1
                )],
                totalUsage: nil, durationMilliseconds: 1,
                cost: .init(availability: .unavailable, usd: nil, explanation: "Fixture"),
                supersedesAssessmentID: nil,
                scoringContract: try? EvaluationScoringContract(suite: suite)
            )
        }

        var baseline = makeRun(cases: suite.cases, statuses: [[.passed]])
        baseline.suiteID = suiteID
        baseline.criteria = suite.criteria
        baseline.suiteRevision = "current"
        baseline.suiteDefinition = EvaluationSuiteDefinition(suite: suite)
        let approvedAssessment = assessment(for: baseline, status: .passed)
        let laterAssessment = assessment(for: baseline, status: .failed)
        baseline.assessments = [approvedAssessment, laterAssessment]
        baseline.selectedAssessmentID = laterAssessment.id

        var current = makeRun(cases: suite.cases, statuses: [[.failed]])
        current.suiteID = suiteID
        current.criteria = suite.criteria
        current.suiteRevision = "current"
        current.suiteDefinition = EvaluationSuiteDefinition(suite: suite)
        let currentAssessment = assessment(for: current, status: .failed)
        current.assessments = [currentAssessment]
        current.selectedAssessmentID = currentAssessment.id
        let approval = EvaluationBaselineApproval(
            id: UUID(), runID: baseline.id, assessmentID: approvedAssessment.id,
            suiteRevision: "current", approvedAt: Date(), note: nil, revokedAt: nil,
            scoringContract: try? EvaluationScoringContract(suite: suite)
        )

        let report = EvaluationReleaseCheckEvaluator.report(
            projectID: UUID(), suite: suite, currentSuiteRevision: "current",
            run: current, baseline: baseline, approvedBaseline: approval
        )

        #expect(report.outcome == .regression)
        #expect(report.failures.contains { $0.contains("Pass rate regressed") })
    }

    @MainActor
    @Test func explicitUnknownReleaseRunDoesNotFallBackToLatestRun() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        var completed = makeRun(cases: store.suite.cases, statuses: [[.passed]])
        completed.suiteID = store.suite.id
        completed.suiteRevision = store.suiteRevision
        store.runs = [completed]

        let report = store.releaseCheckReport(runID: UUID())

        #expect(report.outcome == .incompleteOrIncompatibleEvidence)
        #expect(report.runID == nil)
        #expect(report.failures.contains { $0.contains("No completed run") || $0.contains("Run the suite") })
    }

    @Test func repositoryDefinitionsExcludeLocalJudgeBindings() {
        var suite = EvaluationSuite()
        let connectionID = UUID()
        let approvedAt = Date()
        let connection = EvaluationJudgeConnection(
            id: connectionID, name: "Fixture", kind: .localCompatible,
            baseURL: "http://127.0.0.1:11434/v1", modelID: "judge"
        )
        suite.judgeConfiguration = .init(
            mode: .connection, connectionID: connectionID,
            externalEvidenceApprovedAt: approvedAt, includeReferenceAttachments: false,
            approvedConnectionID: connectionID, approvedIncludeReferenceAttachments: false,
            approvedConnectionDigest: connection.disclosureDigest
        )
        suite.modelConfiguration.coreAISettings.resourcesPath = "/Users/machine-a/Models"
        suite.modelConfiguration.coreAISettings.resourcesBookmark = Data([1, 2, 3])
        suite.features.spotlightSearch.fileSource.folderPath = "/Users/machine-a/Search"

        let definition = EvaluationSuiteDefinition(suite: suite)
        #expect(definition.judgeConfiguration.mode == .connection)
        #expect(definition.judgeConfiguration.connectionID == nil)
        #expect(definition.judgeConfiguration.externalEvidenceApprovedAt == nil)
        #expect(definition.judgeConfiguration.approvedConnectionID == nil)
        #expect(definition.judgeConfiguration.approvedIncludeReferenceAttachments == nil)
        #expect(definition.judgeConfiguration.approvedConnectionDigest == nil)
        #expect(definition.modelConfiguration.coreAI?.resourcesPath.isEmpty == true)
        #expect(definition.modelConfiguration.coreAI?.resourcesBookmark == nil)
        #expect(definition.features.spotlightSearch.fileSource.folderPath.isEmpty)

        var machineB = suite
        machineB.modelConfiguration.coreAISettings.resourcesPath = "/Users/machine-b/Models"
        machineB.modelConfiguration.coreAISettings.resourcesBookmark = Data([9, 8, 7])
        machineB.features.spotlightSearch.fileSource.folderPath = "/Users/machine-b/Search"
        let reapplied = definition.applyingLocalState(from: machineB)
        #expect(reapplied.judgeConfiguration.connectionID == connectionID)
        #expect(reapplied.judgeConfiguration.externalEvidenceApprovedAt == approvedAt)
        #expect(reapplied.judgeConfiguration.includeReferenceAttachments == false)
        #expect(reapplied.judgeConfiguration.hasCurrentExternalEvidenceApproval(for: connection))
        #expect(reapplied.modelConfiguration.coreAI?.resourcesPath == "/Users/machine-b/Models")
        #expect(reapplied.modelConfiguration.coreAI?.resourcesBookmark == Data([9, 8, 7]))
        #expect(reapplied.features.spotlightSearch.fileSource.folderPath == "/Users/machine-b/Search")
    }

    @MainActor
    @Test func changingJudgeDestinationInvalidatesChecksAndSuiteDisclosure() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        var connection = EvaluationJudgeConnection(
            id: UUID(), name: "Local judge", kind: .localCompatible,
            baseURL: "http://127.0.0.1:11434/v1", modelID: "judge-v1",
            lastCheckedAt: Date(), lastCheckMessage: "Verified"
        )
        try store.saveJudgeConnection(connection, apiKey: nil)
        store.draftSuite.judgeConfiguration = .init(mode: .connection, connectionID: connection.id)
        store.approveExternalJudgeDisclosure()
        #expect(store.draftSuite.judgeConfiguration.hasCurrentExternalEvidenceApproval(for: connection))

        connection.modelID = "judge-v2"
        try store.saveJudgeConnection(connection, apiKey: nil)

        let saved = try #require(store.judgeConnections.first { $0.id == connection.id })
        #expect(saved.lastCheckedAt == nil)
        #expect(saved.lastCheckMessage == nil)
        #expect(!store.draftSuite.judgeConfiguration.hasCurrentExternalEvidenceApproval(for: saved))
    }

    @MainActor
    @Test func failedSuiteDefinitionLinkLeavesTheProjectUnlinked() throws {
        let support = try temporaryDirectory()
        let repository = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: repository)
        }
        try runGit(["init"], in: repository)
        try FileManager.default.createDirectory(
            at: repository.appending(path: ".foundation-evals"),
            withIntermediateDirectories: true
        )
        try Data().write(to: repository.appending(path: ".foundation-evals/suites"))
        let store = EvaluationStore(supportDirectory: support)
        let catalogURL = support.appending(path: EvaluationWorkspacePersistence.catalogFilename)
        let catalogBeforeLink = try Data(contentsOf: catalogURL)

        #expect(throws: (any Error).self) {
            try store.linkSelectedProject(toRepository: repository.path)
        }
        #expect(store.selectedProject.repository == nil)
        #expect(store.selectedSuiteRecord.repositoryDefinitionPath == nil)
        #expect(try Data(contentsOf: catalogURL) == catalogBeforeLink)
        let reloaded = EvaluationStore(supportDirectory: support)
        #expect(reloaded.selectedProject.repository == nil)
    }

    @MainActor
    @Test func repositoryDefinitionConflictsDoNotOverwriteEitherSide() throws {
        let support = try temporaryDirectory()
        let repository = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: repository)
        }
        try runGit(["init"], in: repository)
        let store = EvaluationStore(supportDirectory: support)
        try store.linkSelectedProject(toRepository: repository.path)
        guard let definitionURL = EvaluationWorkspacePersistence.repositoryDefinitionURL(
            project: store.selectedProject, suite: store.selectedSuiteRecord
        ) else {
            Issue.record("Expected a linked repository definition.")
            return
        }
        var external = try CanonicalJSON.decode(
            EvaluationSuiteDefinition.self, from: Data(contentsOf: definitionURL)
        )
        external.instructions = "Externally edited instructions"
        let externalData = try CanonicalJSON.data(for: external)
        try externalData.write(to: definitionURL, options: .atomic)

        store.draftSuite.instructions = "Locally edited instructions"
        #expect(store.saveSuite() == false)
        #expect(store.notice?.contains("repository suite changed") == true)
        #expect(try Data(contentsOf: definitionURL) == externalData)
        #expect(store.suite.instructions != "Locally edited instructions")
        let reloaded = EvaluationStore(supportDirectory: support)
        #expect(reloaded.suite.instructions != "Locally edited instructions")
        #expect(reloaded.draftSuite.instructions == "Locally edited instructions")
    }

    @Test func featureAdapterExecutesSharedCodeAndUsesNormalScoring() async {
        var suite = EvaluationSuite()
        suite.scoringMode = .exactMatch
        suite.repetitions = 2
        suite.cases = [EvaluationCase(name: "Feature", prompt: "hello", expected: "HELLO")]
        let adapter = ClosureFeatureAdapter(displayName: "Uppercase") { input in input.prompt.uppercased() }
        let run = await EvaluationFeatureAdapterRunner().run(
            suiteRevision: "feature-v1", suite: suite, adapter: adapter
        )
        #expect(run.results.count == 2)
        #expect(run.results.allSatisfy { $0.status == .passed })
        #expect(run.environment.model == "Feature adapter · Uppercase")
        #expect(run.suiteDefinition?.id == suite.id)
    }

    @MainActor
    @Test func featureAdapterProductionPathPersistsHistoryAndFeedsReleaseChecks() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.scoringMode = .exactMatch
        store.draftSuite.cases = [EvaluationCase(name: "Uppercase", prompt: "ready", expected: "READY")]
        store.draftSuite.releasePolicy.required = true
        #expect(store.saveSuite())
        let adapter = ClosureFeatureAdapter(displayName: "Uppercase feature") { input in
            input.prompt.uppercased()
        }

        let run = try await store.runFeatureAdapter(
            expectedRevision: store.suiteRevision,
            adapter: adapter
        )

        #expect(store.runs.first?.id == run.id)
        #expect(run.results.allSatisfy { $0.status == .passed })
        #expect(run.subjectEvidence?.hasValidDigest == true)
        #expect(store.releaseCheckReport(runID: run.id).outcome == .passed)
        let reloaded = EvaluationStore(supportDirectory: directory)
        #expect(reloaded.run(with: run.id)?.results.first?.response == "READY")
        #expect(reloaded.releaseCheckReport(runID: run.id).outcome == .passed)
    }

    @MainActor
    @Test func featureAdapterAIRubricUsesConfiguredJudgeForInitialAssessment() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try CompatibleJudgeFixture(mode: .valid)
        defer { fixture.stop() }
        let store = EvaluationStore(supportDirectory: directory)
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Initial judge fixture", kind: .localCompatible,
            baseURL: fixture.baseURL, modelID: "judge-fixture"
        )
        try store.saveJudgeConnection(connection, apiKey: nil)
        store.draftSuite.criteria = "The response is accurate and complete."
        store.draftSuite.scoringMode = .modelJudge
        store.draftSuite.cases = [EvaluationCase(name: "Feature", prompt: "ready", expected: "READY")]
        store.draftSuite.judgeConfiguration = .init(mode: .connection, connectionID: connection.id)
        store.approveExternalJudgeDisclosure()

        let run = try await store.runFeatureAdapter(
            expectedRevision: store.suiteRevision,
            adapter: ClosureFeatureAdapter(displayName: "Saved response") { _ in "READY" }
        )

        let assessment = try #require(run.selectedAssessment)
        #expect(assessment.origin == .initialRun)
        #expect(assessment.judge.mode == .connection)
        #expect(assessment.judge.connectionID == connection.id)
        #expect(assessment.subjectEvidenceDigest == run.subjectEvidence?.digest)
        #expect(run.results.first?.status == .unscored)
        #expect(run.effectiveResults.first?.status == .passed)
        #expect(fixture.completionRequestCount == 1)

        let reloaded = EvaluationStore(supportDirectory: directory)
        let persisted = try #require(reloaded.run(with: run.id))
        #expect(persisted.selectedAssessment?.origin == .initialRun)
        #expect(persisted.effectiveResults.first?.status == .passed)
    }

    @MainActor
    @Test func featureAdapterAIRubricJudgeFailurePersistsUnscoredEvidence() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try CompatibleJudgeFixture(mode: .status(503))
        defer { fixture.stop() }
        let store = EvaluationStore(supportDirectory: directory)
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Unavailable judge fixture", kind: .localCompatible,
            baseURL: fixture.baseURL, modelID: "judge-fixture"
        )
        try store.saveJudgeConnection(connection, apiKey: nil)
        store.draftSuite.criteria = "The response is accurate and complete."
        store.draftSuite.scoringMode = .modelJudge
        store.draftSuite.cases = [EvaluationCase(name: "Feature", prompt: "ready", expected: "READY")]
        store.draftSuite.judgeConfiguration = .init(mode: .connection, connectionID: connection.id)
        store.approveExternalJudgeDisclosure()

        let run = try await store.runFeatureAdapter(
            expectedRevision: store.suiteRevision,
            adapter: ClosureFeatureAdapter(displayName: "Saved response") { _ in "READY" }
        )

        let result = try #require(run.effectiveResults.first)
        #expect(run.selectedAssessment?.origin == .initialRun)
        #expect(result.status == .unscored)
        #expect(result.judgeErrorCategory == "serviceUnavailable")
        #expect(result.judgeErrorMessage != nil)
        #expect(run.passedCount == 0)
        #expect(EvaluationStore(supportDirectory: directory).run(with: run.id)?.passedCount == 0)
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func featureAdapterAIRubricCancellationPersistsUnscoredEvidence() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try CompatibleJudgeFixture(mode: .stalled)
        defer { fixture.stop() }
        let store = EvaluationStore(supportDirectory: directory)
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Stalled initial judge", kind: .localCompatible,
            baseURL: fixture.baseURL, modelID: "judge-fixture"
        )
        try store.saveJudgeConnection(connection, apiKey: nil)
        store.draftSuite.criteria = "The response is accurate and complete."
        store.draftSuite.scoringMode = .modelJudge
        store.draftSuite.cases = [EvaluationCase(name: "Feature", prompt: "ready", expected: "READY")]
        store.draftSuite.judgeConfiguration = .init(mode: .connection, connectionID: connection.id)
        store.approveExternalJudgeDisclosure()

        let task = Task { @MainActor in
            try await store.runFeatureAdapter(
                expectedRevision: store.suiteRevision,
                adapter: ClosureFeatureAdapter(displayName: "Saved response") { _ in "READY" }
            )
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while fixture.completionRequestCount < 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(fixture.completionRequestCount == 1, "Judge fixture did not receive the initial assessment request.")

        task.cancel()
        let run = try await task.value

        let result = try #require(run.effectiveResults.first)
        #expect(run.cancelled)
        #expect(run.terminationReason == "cancelled")
        #expect(run.selectedAssessment?.origin == .initialRun)
        #expect(result.status == .unscored)
        #expect(result.judgeErrorCategory == "cancelled")
        #expect(result.judgeErrorMessage != nil)
        #expect(EvaluationStore(supportDirectory: directory).run(with: run.id)?.cancelled == true)
    }

    @MainActor
    @Test func featureAdapterAIRubricRequiresIndependentJudgeBeforeExecution() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let invoked = FeatureInvocationCounter()
        store.draftSuite.criteria = "The response is accurate and complete."
        store.draftSuite.scoringMode = .modelJudge
        #expect(store.saveSuite())

        await #expect(throws: EvaluationStoreError.self) {
            try await store.runFeatureAdapter(
                expectedRevision: store.suiteRevision,
                adapter: ClosureFeatureAdapter(displayName: "Must not execute") { _ in
                    await invoked.increment()
                    return "READY"
                }
            )
        }

        #expect(await invoked.value == 0)
        #expect(store.runs.isEmpty)
    }

    @MainActor
    @Test func developerRunnerIdentityPersistsWithNormalRunEvidence() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.scoringMode = .exactMatch
        store.draftSuite.cases = [EvaluationCase(name: "Device", prompt: "ready", expected: "READY")]
        #expect(store.saveSuite())
        let runnerID = UUID()
        let adapter = PersistedDeveloperFixtureAdapter(runnerID: runnerID)

        let run = try await store.runFeatureAdapter(
            expectedRevision: store.suiteRevision,
            adapter: adapter
        )

        #expect(run.results.first?.status == .passed)
        #expect(run.environment.operatingSystem == "iOS 27.0")
        #expect(run.developerExecution?.runnerID == runnerID)
        #expect(run.developerExecution?.featureID == "com.example.actual-feature")
        let reloaded = EvaluationStore(supportDirectory: directory)
        #expect(reloaded.run(with: run.id)?.developerExecution == run.developerExecution)
        #expect(reloaded.run(with: run.id)?.subjectEvidence?.hasValidDigest == true)
    }

    @MainActor
    @Test func developerRunnerDisconnectTerminatesAndPersistsIncompleteRun() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.scoringMode = .exactMatch
        store.draftSuite.cases = [
            EvaluationCase(name: "First", prompt: "one", expected: "ONE"),
            EvaluationCase(name: "Second", prompt: "two", expected: "TWO"),
        ]
        #expect(store.saveSuite())

        let run = try await store.runFeatureAdapter(
            expectedRevision: store.suiteRevision,
            adapter: DisconnectedDeveloperFixtureAdapter()
        )

        #expect(run.terminationReason == "developerRunner:disconnected")
        #expect(run.cancelled == false)
        #expect(run.results.count == 1)
        #expect(run.results.first?.status == .error)
        let reloaded = EvaluationStore(supportDirectory: directory)
        #expect(reloaded.run(with: run.id)?.terminationReason == "developerRunner:disconnected")
    }

    @MainActor
    @Test func developerRunnerCancellationRetainsExecutionIdentityUntilTeardown() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DeveloperRunnerStore(evaluationStore: EvaluationStore(supportDirectory: directory))

        let cancelledRunID = UUID()
        let cancelGate = DeveloperTrackedExecutionGate()
        store.startTrackedExecution(runID: cancelledRunID) {
            await cancelGate.markStarted()
            try? await Task.sleep(for: .seconds(60))
        }
        await cancelGate.waitUntilStarted()

        #expect(store.executingRunID == cancelledRunID)
        store.cancelRun(cancelledRunID)
        #expect(store.executingRunID == cancelledRunID)
        await waitForDeveloperExecutionTeardown(store)
        #expect(store.executingRunID == nil)

        let stoppedRunID = UUID()
        let stopGate = DeveloperTrackedExecutionGate()
        store.startTrackedExecution(runID: stoppedRunID) {
            await stopGate.markStarted()
            try? await Task.sleep(for: .seconds(60))
        }
        await stopGate.waitUntilStarted()

        store.stop()
        #expect(store.executingRunID == stoppedRunID)
        await waitForDeveloperExecutionTeardown(store)
        #expect(store.executingRunID == nil)
    }

    @MainActor
    private func waitForDeveloperExecutionTeardown(_ store: DeveloperRunnerStore) async {
        for _ in 0..<100 where store.executingRunID != nil {
            await Task.yield()
        }
    }

    @MainActor
    @Test func reassessmentRetainsOriginalInstructionsAndRunOwnedImageBytes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.instructions = "Original subject instructions"
        store.draftSuite.criteria = "The response follows the saved task instructions."
        store.draftSuite.scoringMode = .modelJudge
        store.draftSuite.cases[0].expected = "READY"
        #expect(store.saveSuite())
        let imageData = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let image = try await store.importAttachment(
            id: UUID(), name: "source.png", mediaType: "image/png", data: imageData,
            expectedRevision: store.suiteRevision
        )
        let fixture = try CompatibleJudgeFixture(mode: .valid)
        defer { fixture.stop() }
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Replay fixture", kind: .localCompatible,
            baseURL: fixture.baseURL, modelID: "judge-fixture",
            capabilities: .init(structuredOutputs: true, multimodal: true)
        )
        try store.saveJudgeConnection(connection, apiKey: nil)
        store.draftSuite.judgeConfiguration = .init(mode: .connection, connectionID: connection.id)
        store.approveExternalJudgeDisclosure()
        let run = try await store.runFeatureAdapter(
            expectedRevision: store.suiteRevision,
            adapter: ClosureFeatureAdapter(displayName: "Saved response") { _ in "READY" }
        )
        let evidence = try #require(run.subjectEvidence)
        let storedFilename = try #require(evidence.attachments.first(where: { $0.id == image.attachment.id })?.storedFilename)
        let evidenceURL = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory,
            projectID: store.selectedProjectID,
            suiteID: store.selectedSuiteID
        ).appending(path: "RunEvidence/\(run.id.uuidString)/\(storedFilename)")
        #expect(try Data(contentsOf: evidenceURL) == imageData)

        store.draftSuite.instructions = "Replacement instructions that must not rewrite history"
        #expect(store.saveSuite())
        _ = try store.removeAttachment(id: image.attachment.id, expectedRevision: store.suiteRevision)
        #expect(!store.suite.attachments.contains { $0.id == image.attachment.id })
        #expect(try Data(contentsOf: evidenceURL) == imageData)

        store.reassessRun(id: run.id, connectionID: connection.id)
        try await waitForReassessment(store)
        let reassessed = try #require(store.run(with: run.id)?.selectedAssessment)
        #expect(reassessed.origin == .reassessment)
        #expect(reassessed.samples.first?.status == .passed)
        #expect(reassessed.subjectEvidenceDigest == evidence.digest)
        #expect(store.run(with: run.id)?.subjectEvidence?.instructions == "Original subject instructions")
        let request = try #require(fixture.lastCompletionRequest)
        #expect(request.contains("Original subject instructions"))
        #expect(!request.contains("Replacement instructions that must not rewrite history"))
        #expect(request.contains(imageData.base64EncodedString()))
    }

    @MainActor
    @Test func workspaceSwitchingIsBlockedDuringReassessmentAndJudgeChecks() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let originalSuiteID = store.selectedSuiteID
        let secondSuiteID = try store.createSuite(name: "Second suite")
        try store.switchSuite(id: originalSuiteID)
        store.draftSuite.criteria = "The response is exactly READY."
        store.draftSuite.scoringMode = .modelJudge
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Deterministic check", kind: .localCompatible,
            baseURL: "http://127.0.0.1:1/v1", modelID: "unused"
        )
        try store.saveJudgeConnection(connection, apiKey: nil)
        store.draftSuite.judgeConfiguration = .init(mode: .connection, connectionID: connection.id)
        store.approveExternalJudgeDisclosure()
        let run = try await store.runFeatureAdapter(
            expectedRevision: store.suiteRevision,
            adapter: ClosureFeatureAdapter(displayName: "Saved response") { _ in "READY" }
        )

        store.reassessRun(id: run.id, connectionID: connection.id)
        #expect(throws: EvaluationStoreError.self) { try store.switchSuite(id: secondSuiteID) }
        try await waitForReassessment(store)
        let assessment = try #require(store.run(with: run.id)?.selectedAssessment)
        try store.markJudgmentIncorrect(
            runID: run.id, assessmentID: assessment.id, sampleID: run.results[0].id,
            correctedStatus: .failed, correctedScore: 1, reason: "Known calibration example",
            collectAsJudgeCheck: true
        )
        store.runJudgeChecks(connectionID: connection.id)
        #expect(throws: EvaluationStoreError.self) { try store.switchSuite(id: secondSuiteID) }
        try await waitForReassessment(store)
        #expect(store.selectedSuiteID == originalSuiteID)
        #expect(store.latestJudgeCheck?.results.first?.example.sourceRunID == run.id)
    }

    @Test func structuredStarterUsesFieldAssertionsAsDeterministicScores() async {
        let suite = EvaluationStarterPack.structuredExtraction.makeSuite()
        let adapter = ClosureFeatureAdapter(displayName: "Expected fixture") { input in input.expected }

        let run = await EvaluationFeatureAdapterRunner().run(
            suiteRevision: "structured-v1", suite: suite, adapter: adapter
        )

        #expect(run.results.count == suite.cases.count)
        #expect(run.results.allSatisfy { $0.status == .passed })
        #expect(run.results.allSatisfy { $0.fieldAssertionResults?.isEmpty == false })
    }

    @MainActor
    @Test func projectReleaseReportEnforcesEveryRequiredSuite() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let projectID = store.selectedProjectID
        let firstSuiteID = store.selectedSuiteID
        store.draftSuite.scoringMode = .exactMatch
        store.draftSuite.cases = [EvaluationCase(name: "First", prompt: "one", expected: "ONE")]
        store.draftSuite.releasePolicy.required = true
        #expect(store.saveSuite())
        _ = try await store.runFeatureAdapter(
            expectedRevision: store.suiteRevision,
            adapter: ClosureFeatureAdapter(displayName: "Uppercase") { $0.prompt.uppercased() }
        )

        let secondSuiteID = try store.createSuite(name: "Second required")
        store.draftSuite.scoringMode = .exactMatch
        store.draftSuite.cases = [EvaluationCase(name: "Second", prompt: "two", expected: "TWO")]
        store.draftSuite.releasePolicy.required = true
        store.draftSuite.releasePolicy.criticalCaseIDs = [store.draftSuite.cases[0].id]
        #expect(store.saveSuite())

        var report = try store.projectReleaseCheckReport(projectID: projectID)
        #expect(report.outcome == .incompleteOrIncompatibleEvidence)
        #expect(report.suites.count == 2)
        #expect(report.suites.first(where: { $0.suiteID == secondSuiteID })?.report.runID == nil)

        let failedRun = try await store.runFeatureAdapter(
            expectedRevision: store.suiteRevision,
            adapter: ClosureFeatureAdapter(displayName: "Wrong") { _ in "WRONG" }
        )
        #expect(store.runs.first?.failedCount == 1)
        #expect(store.runs.first?.id == failedRun.id)
        let reloadedAfterFailure = EvaluationStore(supportDirectory: directory)
        #expect(reloadedAfterFailure.selectedSuiteID == secondSuiteID)
        #expect(reloadedAfterFailure.runs.first?.id == failedRun.id)
        report = try store.projectReleaseCheckReport(projectID: projectID)
        #expect(report.suites.first(where: { $0.suiteID == secondSuiteID })?.report.outcome == .regression)
        #expect(report.outcome == .regression)

        let baseline = try await store.runFeatureAdapter(
            expectedRevision: store.suiteRevision,
            adapter: ClosureFeatureAdapter(displayName: "Uppercase") { $0.prompt.uppercased() }
        )
        try store.approveBaseline(runID: baseline.id, assessmentID: nil)
        store.draftSuite.releasePolicy.requireApprovedBaseline = true
        #expect(store.saveSuite())
        _ = try await store.runFeatureAdapter(
            expectedRevision: store.suiteRevision,
            adapter: ClosureFeatureAdapter(displayName: "Uppercase") { $0.prompt.uppercased() }
        )
        report = try store.projectReleaseCheckReport(projectID: projectID)
        #expect(report.outcome == .passed)

        store.draftSuite.instructions = "A newer subject prompt"
        #expect(store.saveSuite())
        report = try store.projectReleaseCheckReport(projectID: projectID)
        #expect(report.outcome == .incompleteOrIncompatibleEvidence)
        #expect(report.suites.first(where: { $0.suiteID == secondSuiteID })?.report.failures.contains {
            $0.contains("stale")
        } == true)

        _ = try await store.runFeatureAdapter(
            expectedRevision: store.suiteRevision,
            adapter: ClosureFeatureAdapter(displayName: "Uppercase") { $0.prompt.uppercased() }
        )
        store.draftSuite.cases[0].prompt = "changed case"
        store.draftSuite.cases[0].expected = "CHANGED CASE"
        #expect(store.saveSuite())
        _ = try await store.runFeatureAdapter(
            expectedRevision: store.suiteRevision,
            adapter: ClosureFeatureAdapter(displayName: "Uppercase") { $0.prompt.uppercased() }
        )
        report = try store.projectReleaseCheckReport(projectID: projectID)
        #expect(report.outcome == .incompleteOrIncompatibleEvidence)
        #expect(report.suites.first(where: { $0.suiteID == secondSuiteID })?.report.failures.contains {
            $0.contains("approved baseline uses incompatible")
        } == true)
        #expect(report.suites.contains { $0.suiteID == firstSuiteID && $0.report.outcome == .passed })
    }

    @MainActor
    @Test func projectReleaseReportReadsRepositoryChangesForNonselectedSuitesWithoutPersisting() throws {
        let support = try temporaryDirectory()
        let repository = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: repository)
        }
        try runGit(["init"], in: repository)
        let store = EvaluationStore(supportDirectory: support)
        let projectID = store.selectedProjectID
        let linkedSuiteID = try store.createSuite(name: "Repository required")
        #expect(store.suite.releasePolicy.required == false)
        try store.linkSelectedProject(toRepository: repository.path)
        let linkedRecord = try #require(store.selectedProject.suites.first { $0.id == linkedSuiteID })
        let definitionURL = try #require(EvaluationWorkspacePersistence.repositoryDefinitionURL(
            project: store.selectedProject,
            suite: linkedRecord
        ))
        var repositoryDefinition = try CanonicalJSON.decode(
            EvaluationSuiteDefinition.self,
            from: Data(contentsOf: definitionURL)
        )
        repositoryDefinition.releasePolicy.required = true
        try CanonicalJSON.data(for: repositoryDefinition).write(to: definitionURL, options: .atomic)

        let selectedSuiteID = try store.createSuite(name: "Still selected")
        let linkedSuiteURL = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: support,
            projectID: projectID,
            suiteID: linkedSuiteID
        ).appending(path: "suite.json")
        let localSuiteBefore = try Data(contentsOf: linkedSuiteURL)
        let catalogURL = support.appending(path: EvaluationWorkspacePersistence.catalogFilename)
        let catalogBefore = try Data(contentsOf: catalogURL)

        let report = try store.projectReleaseCheckReport(projectID: projectID)

        #expect(report.outcome == .incompleteOrIncompatibleEvidence)
        #expect(report.suites.contains { $0.suiteID == linkedSuiteID && $0.required })
        #expect(store.selectedSuiteID == selectedSuiteID)
        #expect(try Data(contentsOf: linkedSuiteURL) == localSuiteBefore)
        #expect(try Data(contentsOf: catalogURL) == catalogBefore)
    }

    @MainActor
    @Test func projectReleaseReportDoesNotCreateBackupsForUnreadableSuites() throws {
        let support = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let store = EvaluationStore(supportDirectory: support)
        let projectID = store.selectedProjectID
        let originalSuiteID = store.selectedSuiteID
        let brokenSuiteID = try store.createSuite(name: "Unreadable")
        try store.switchSuite(id: originalSuiteID)
        let brokenSuiteURL = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: support,
            projectID: projectID,
            suiteID: brokenSuiteID
        ).appending(path: "suite.json")
        try Data("not-json".utf8).write(to: brokenSuiteURL, options: .atomic)
        let pathsBefore = try FileManager.default.subpathsOfDirectory(atPath: support.path).sorted()

        let first = try store.projectReleaseCheckReport(projectID: projectID)
        let second = try store.projectReleaseCheckReport(projectID: projectID)

        #expect(first.outcome == .incompleteOrIncompatibleEvidence)
        #expect(second.outcome == .incompleteOrIncompatibleEvidence)
        #expect(first.suites.contains { $0.suiteID == brokenSuiteID })
        #expect(try FileManager.default.subpathsOfDirectory(atPath: support.path).sorted() == pathsBefore)
    }

    @MainActor
    @Test func corruptLocalStateAndJudgeConnectionsArePreservedAndSurfaced() throws {
        let support = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let store = EvaluationStore(supportDirectory: support)
        store.draftSuite.releasePolicy.required = true
        #expect(store.saveSuite())
        let suiteDirectory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: support,
            projectID: store.selectedProjectID,
            suiteID: store.selectedSuiteID
        )
        let stateURL = suiteDirectory.appending(path: "state.json")
        let connectionsURL = support.appending(path: "judge-connections.json")
        let corruptState = Data("not-state-json".utf8)
        let corruptConnections = Data("not-connections-json".utf8)
        try corruptState.write(to: stateURL, options: .atomic)
        try corruptConnections.write(to: connectionsURL, options: .atomic)

        let restored = EvaluationStore(supportDirectory: support)

        #expect(restored.notice?.contains("saved suite state could not be read") == true)
        #expect(restored.notice?.contains("saved judge connections could not be read") == true)
        let reloaded = EvaluationStore(supportDirectory: support)
        #expect(reloaded.notice?.contains("saved suite state could not be read") == true)
        #expect(reloaded.notice?.contains("saved judge connections could not be read") == true)
        let suiteFiles = try FileManager.default.contentsOfDirectory(atPath: suiteDirectory.path)
        let stateBackups = suiteFiles.filter { $0.hasPrefix("state-unreadable-") }
        #expect(stateBackups.count == 1)
        let stateBackup = try #require(stateBackups.first)
        #expect(try Data(contentsOf: suiteDirectory.appending(path: stateBackup)) == corruptState)
        let rootFiles = try FileManager.default.contentsOfDirectory(atPath: support.path)
        let connectionBackups = rootFiles.filter { $0.hasPrefix("judge-connections-unreadable-") }
        #expect(connectionBackups.count == 1)
        let connectionsBackup = try #require(connectionBackups.first)
        #expect(try Data(contentsOf: support.appending(path: connectionsBackup)) == corruptConnections)
    }

    @MainActor
    @Test func projectReleaseReportFailsClosedOnUnreadableSuiteStateWithoutWriting() throws {
        let support = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let store = EvaluationStore(supportDirectory: support)
        store.draftSuite.releasePolicy.required = true
        #expect(store.saveSuite())
        let suiteDirectory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: support,
            projectID: store.selectedProjectID,
            suiteID: store.selectedSuiteID
        )
        try Data("not-state-json".utf8).write(
            to: suiteDirectory.appending(path: "state.json"),
            options: .atomic
        )
        let pathsBefore = try FileManager.default.subpathsOfDirectory(atPath: support.path).sorted()

        let report = try store.projectReleaseCheckReport(projectID: store.selectedProjectID)

        #expect(report.outcome == .incompleteOrIncompatibleEvidence)
        #expect(report.suites.first?.report.failures.contains { $0.contains("unreadable suite state") } == true)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: support.path).sorted() == pathsBefore)
    }

    @MainActor
    @Test func targetedMCPListsAndActivatesStableWorkspaceIDs() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.releasePolicy.required = true
        #expect(store.saveSuite())
        let original = store.selectedSuiteID
        let second = try store.createSuite(name: "Automation target")
        try store.switchSuite(id: original)
        let authority = MCPStoreAuthority.make(store: store)
        let catalog = await authority.call(.listProjects).structuredContent
        guard case .array(let projects)? = catalog.objectValue?["projects"] else {
            Issue.record("Expected projects array.")
            return
        }
        #expect(!projects.isEmpty)
        let projectReport = await authority.call(.projectReleaseReport(.init(
            projectID: store.selectedProjectID
        )))
        #expect(!projectReport.isError)
        #expect(projectReport.structuredContent.objectValue?["outcome"] == .string("read"))
        #expect(projectReport.structuredContent.objectValue?["report"]?.objectValue?["outcome"] == .integer(20))
        #expect(store.selectedSuiteID == original)
        let report = await authority.call(.releaseReport(.init(
            projectID: store.selectedProjectID, suiteID: second, runID: nil
        )))
        #expect(!report.isError)
        #expect(store.selectedSuiteID == second)
        #expect(report.structuredContent.objectValue?["report"]?.objectValue?["outcome"] == .integer(20))
    }

    @Test func repositorySnapshotRecordsCommitAndDirtyTree() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try runGit(["init"], in: directory)
        try runGit(["config", "user.email", "fixture@example.com"], in: directory)
        try runGit(["config", "user.name", "Fixture"], in: directory)
        try Data("one".utf8).write(to: directory.appending(path: "fixture.txt"))
        try runGit(["add", "fixture.txt"], in: directory)
        try runGit(["commit", "-m", "fixture"], in: directory)
        var snapshot = await EvaluationRepositoryInspector.snapshot(rootPath: directory.path)
        #expect(snapshot.commit?.isEmpty == false)
        #expect(snapshot.isDirty == false)
        try Data("two".utf8).write(to: directory.appending(path: "fixture.txt"))
        snapshot = await EvaluationRepositoryInspector.snapshot(rootPath: directory.path)
        #expect(snapshot.isDirty == true)
    }

    @Test func reassessmentReappliesFieldAssertionsWithoutGeneration() async throws {
        var suite = EvaluationSuite()
        suite.criteria = "The response is exactly READY."
        suite.cases[0].fieldAssertions = [
            .init(pointer: "/verified", operation: .equals, expectedValue: "true")
        ]
        var run = makeRun(cases: suite.cases, statuses: [[.passed]])
        run.suiteID = suite.id
        run.results[0].response = "READY"
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Unused fixture", kind: .localCompatible,
            baseURL: "http://127.0.0.1:1/v1", modelID: "unused"
        )

        let assessment = try await EvaluationReassessmentService().reassess(
            run: run, suite: suite, images: [],
            resolved: .init(connection: connection, apiKey: nil)
        )

        #expect(assessment.origin == .reassessment)
        #expect(assessment.samples.count == 1)
        #expect(assessment.samples[0].status == .failed)
        #expect(assessment.samples[0].trace?.judgedCriterionIndexes == [])
        #expect(assessment.errorCount == 0)
        #expect(assessment.durationMilliseconds == 0)
    }

    @Test func failedReassessmentRecordsJudgeAttemptDuration() async throws {
        var suite = EvaluationSuite()
        suite.criteria = "The answer is supported by the evidence."
        var run = makeRun(cases: suite.cases, statuses: [[.passed]])
        run.results[0].response = "A complete response."
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Unavailable fixture", kind: .localCompatible,
            baseURL: "http://127.0.0.1:1/v1", modelID: "unavailable"
        )
        suite.judgeConfiguration = .init(
            mode: .connection,
            connectionID: connection.id,
            externalEvidenceApprovedAt: Date(),
            includeReferenceAttachments: false,
            approvedConnectionID: connection.id,
            approvedIncludeReferenceAttachments: false,
            approvedConnectionDigest: connection.disclosureDigest
        )

        let assessment = try await EvaluationReassessmentService().reassess(
            run: run, suite: suite, images: [],
            resolved: .init(connection: connection, apiKey: nil)
        )

        let sampleDuration = assessment.samples[0].durationMilliseconds
        #expect(sampleDuration != nil)
        #expect(assessment.durationMilliseconds == sampleDuration)
        #expect(assessment.samples[0].errorCategory == "serviceUnavailable")
    }

    @Test func fatalReassessmentFailureStopsBeforeLaterSavedSamples() async throws {
        var suite = EvaluationSuite()
        suite.criteria = "The answer is supported by the evidence."
        suite.cases.append(EvaluationCase(name: "Later case", prompt: "Later", expected: "Later"))
        var run = makeRun(cases: suite.cases, statuses: [[.passed], [.passed]])
        for index in run.results.indices { run.results[index].response = "A complete response." }
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Unavailable fixture", kind: .localCompatible,
            baseURL: "http://127.0.0.1:1/v1", modelID: "unavailable"
        )
        suite.judgeConfiguration = .init(
            mode: .connection, connectionID: connection.id,
            externalEvidenceApprovedAt: Date(), includeReferenceAttachments: false,
            approvedConnectionID: connection.id, approvedIncludeReferenceAttachments: false,
            approvedConnectionDigest: connection.disclosureDigest
        )

        let assessment = try await EvaluationReassessmentService().reassess(
            run: run, suite: suite, images: [],
            resolved: .init(connection: connection, apiKey: nil)
        )

        #expect(assessment.samples.count == 1)
        #expect(assessment.samples[0].sampleID == run.results[0].id)
        #expect(assessment.samples[0].errorCategory == "serviceUnavailable")
        #expect(assessment.errorCount == 1)
    }

    @MainActor
    @Test func incompleteSubjectResponseCannotBecomeKnownGoodJudgeCheck() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        var run = makeRun(cases: store.suite.cases, statuses: [[.unscored]])
        run.suiteID = store.suite.id
        run.results[0].response = "   "
        run.results[0].errorCategory = "modelUnavailable"
        let assessment = try makeAssessment(
            run: run, suite: store.suite, status: .unscored, judge: fixtureJudge()
        )
        run.assessments = [assessment]
        run.selectedAssessmentID = assessment.id
        store.runs = [run]

        #expect(throws: EvaluationStoreError.self) {
            try store.markJudgmentIncorrect(
                runID: run.id, assessmentID: assessment.id, sampleID: run.results[0].id,
                correctedStatus: .failed, correctedScore: 1, reason: "Generation failed.",
                collectAsJudgeCheck: true
            )
        }
        #expect(store.suiteLocalState.humanCorrections.isEmpty)
        #expect(store.suiteLocalState.reviewedJudgeExamples.isEmpty)

        try store.markJudgmentIncorrect(
            runID: run.id, assessmentID: assessment.id, sampleID: run.results[0].id,
            correctedStatus: .failed, correctedScore: 1, reason: "Record the correction only.",
            collectAsJudgeCheck: false
        )
        #expect(store.suiteLocalState.humanCorrections.count == 1)
        #expect(store.suiteLocalState.reviewedJudgeExamples.isEmpty)

        let example = EvaluationReviewedJudgeExample(
            id: UUID(), sourceRunID: run.id, sourceAssessmentID: assessment.id,
            sampleID: run.results[0].id, expectedStatus: .failed,
            reason: "Known failure", createdAt: Date()
        )
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Must not be called", kind: .localCompatible,
            baseURL: "http://127.0.0.1:1/v1", modelID: "unused"
        )
        let report = try await EvaluationReassessmentService().checkJudge(
            sources: [.init(
                example: example, run: run, assessment: assessment,
                suite: store.suite, images: [], errorMessage: nil
            )],
            resolved: .init(connection: connection, apiKey: nil)
        )
        #expect(report.results.count == 1)
        #expect(report.results[0].actualStatus == .unscored)
        #expect(!report.results[0].passed)
        #expect(report.results[0].errorMessage?.contains("no complete subject response") == true)
    }

    @Test func cancelledReassessmentStopsInsteadOfRecordingJudgeFailure() async {
        var suite = EvaluationSuite()
        suite.criteria = "The answer is supported by the evidence."
        var run = makeRun(cases: suite.cases, statuses: [[.passed]])
        run.results[0].response = "A complete response."
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Unused fixture", kind: .localCompatible,
            baseURL: "http://127.0.0.1:1/v1", modelID: "unused"
        )
        suite.judgeConfiguration = .init(
            mode: .connection,
            connectionID: connection.id,
            externalEvidenceApprovedAt: Date(),
            includeReferenceAttachments: false,
            approvedConnectionID: connection.id,
            approvedIncludeReferenceAttachments: false,
            approvedConnectionDigest: connection.disclosureDigest
        )

        let result = await Task { () -> Result<EvaluationAssessment, Error> in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                return .success(try await EvaluationReassessmentService().reassess(
                    run: run, suite: suite, images: [],
                    resolved: .init(connection: connection, apiKey: nil)
                ))
            } catch {
                return .failure(error)
            }
        }.value

        guard case .failure(let error) = result else {
            Issue.record("Expected cancellation to stop reassessment.")
            return
        }
        #expect(error is CancellationError)
    }

    @MainActor
    @Test func correctionsAndBaselineApprovalsPreserveProvenanceDurably() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.criteria = "The response is exactly READY."
        #expect(store.saveSuite())
        var run = makeRun(cases: store.suite.cases, statuses: [[.passed]])
        run.suiteID = store.suite.id
        run.suiteRevision = store.suiteRevision
        run.results[0].response = "READY"
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Unused fixture", kind: .localCompatible,
            baseURL: "http://127.0.0.1:1/v1", modelID: "unused"
        )
        let assessment = try await EvaluationReassessmentService().reassess(
            run: run, suite: store.suite, images: [],
            resolved: .init(connection: connection, apiKey: nil)
        )
        run.assessments = [assessment]
        run.selectedAssessmentID = assessment.id
        store.runs = [run]

        try store.markJudgmentIncorrect(
            runID: run.id, assessmentID: assessment.id, sampleID: run.results[0].id,
            correctedStatus: .failed, correctedScore: 1,
            reason: "The expected status was reviewed manually.", reviewer: "Test reviewer",
            collectAsJudgeCheck: true
        )
        try store.approveBaseline(runID: run.id, assessmentID: assessment.id, note: "Known fixture")

        #expect(store.runs[0].selectedAssessment?.samples[0].status == .passed)
        #expect(store.suiteLocalState.humanCorrections.last?.originalStatus == .passed)
        #expect(store.suiteLocalState.humanCorrections.last?.correctedStatus == .failed)
        #expect(store.suiteLocalState.reviewedJudgeExamples.last?.expectedStatus == .failed)
        #expect(store.activeBaselineApproval?.runID == run.id)
        #expect(store.activeBaselineApproval?.assessmentID == assessment.id)

        let reloaded = EvaluationStore(supportDirectory: directory)
        #expect(reloaded.suiteLocalState.humanCorrections.count == 1)
        #expect(reloaded.suiteLocalState.reviewedJudgeExamples.count == 1)
        #expect(reloaded.activeBaselineApproval?.assessmentID == assessment.id)
    }

    private func makeRun(cases: [EvaluationCase], statuses: [[EvaluationResultStatus]]) -> EvaluationRun {
        let now = Date()
        let results = zip(cases, statuses).flatMap { evaluationCase, caseStatuses in
            caseStatuses.enumerated().map { offset, status in
                EvaluationSampleResult(
                    caseID: evaluationCase.id, caseName: evaluationCase.name,
                    repetition: offset + 1, prompt: evaluationCase.prompt, expected: evaluationCase.expected,
                    response: "response", status: status, score: status == .passed ? 4 : 2,
                    rationale: nil, durationMilliseconds: Double(offset + 1), usage: .init(),
                    judgeDurationMilliseconds: nil, judgeUsage: nil,
                    errorCategory: nil, errorMessage: nil, judgeErrorCategory: nil, judgeErrorMessage: nil
                )
            }
        }
        return EvaluationRun(
            id: UUID(), suiteID: UUID(), suiteName: "Suite", suiteVersion: "v1",
            instructions: "", criteria: "Requirement", scoringMode: .modelJudge,
            repetitions: statuses.first?.count ?? 1,
            judgePromptVersion: EvaluationRunner.judgePromptVersion,
            judgePassingScore: EvaluationSuite.judgePassingScore,
            plannedSampleCount: results.count, suiteRevision: "current", plannedCases: cases,
            startedAt: now, completedAt: now.addingTimeInterval(1), cancelled: false,
            terminationReason: nil,
            environment: .init(operatingSystem: "Test", locale: "en", model: "Fixture", modelContextSize: 1),
            attachments: [], results: results
        )
    }

    private func fixtureJudge() -> EvaluationJudgeIdentity {
        EvaluationJudgeIdentity(
            mode: .connection, connectionID: UUID(), connectionName: "Fixture",
            endpointKind: .customCompatible, baseURL: "https://judge.example",
            requestedModelID: "judge-v1", reportedModelID: "judge-v1",
            provider: "fixture", providerOrder: []
        )
    }

    private func makeAssessment(
        run: EvaluationRun,
        suite: EvaluationSuite,
        status: EvaluationResultStatus,
        judge: EvaluationJudgeIdentity
    ) throws -> EvaluationAssessment {
        EvaluationAssessment(
            id: UUID(), runID: run.id, createdAt: Date(), origin: .reassessment,
            judge: judge, promptVersion: EvaluationRunner.judgePromptVersion,
            rubric: suite.criteria, passingScore: EvaluationSuite.judgePassingScore,
            samples: run.results.map { result in
                EvaluationSampleAssessment(
                    id: UUID(), sampleID: result.id, status: status,
                    score: status == .passed ? 4 : 2, rationale: "Fixture",
                    trace: nil, errorCategory: nil, errorMessage: nil,
                    usage: nil, durationMilliseconds: 1
                )
            },
            totalUsage: nil, durationMilliseconds: 1,
            cost: .init(availability: .unavailable, usd: nil, explanation: "Fixture"),
            supersedesAssessmentID: nil, observedJudgeIdentities: [judge],
            scoringContract: try EvaluationScoringContract(suite: suite),
            subjectEvidenceDigest: run.subjectEvidence?.digest
        )
    }

    @MainActor
    private func waitForReassessment(_ store: EvaluationStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.isReassessing, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!store.isReassessing, "Reassessment did not finish within five seconds.")
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CLIErrorForTests.git }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "EvaluationDevelopmentWorkflowTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct PersistedDeveloperFixtureAdapter: EvaluationFeatureAdapter {
    let runnerID: UUID

    var displayName: String { "Actual app feature" }
    var environment: EvaluationEnvironment {
        .init(
            operatingSystem: "iOS 27.0",
            locale: "en_GB",
            model: "App feature · Actual app feature",
            modelContextSize: 0
        )
    }
    var developerExecution: EvaluationDeveloperExecution? {
        .init(
            runnerID: runnerID,
            runnerName: "Fixture iPhone",
            platform: "iPhone",
            operatingSystem: "iOS 27.0",
            hardwareModel: "iPhone fixture",
            appBundleIdentifier: "com.example.fixture",
            appVersion: "1.0",
            featureID: "com.example.actual-feature",
            featureVersion: "1",
            protocolMajorVersion: 1,
            protocolMinorVersion: 0
        )
    }

    func evaluate(_ input: EvaluationFeatureInput) async throws -> EvaluationFeatureOutput {
        .init(response: input.prompt.uppercased())
    }
}

private struct DisconnectedDeveloperFixtureAdapter: EvaluationFeatureAdapter {
    var displayName: String { "Disconnected runner" }

    func evaluate(_ input: EvaluationFeatureInput) async throws -> EvaluationFeatureOutput {
        throw DeveloperExecutionFailure(code: .disconnected, message: "Fixture runner disconnected.")
    }
}

private actor DeveloperTrackedExecutionGate {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor FeatureInvocationCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private enum CLIErrorForTests: Error { case git }
