import Foundation
import Testing
@testable import FoundationEvals

struct MCPStoreAuthorityTests {
    @MainActor
    @Test func stateUsesOneAuthoritativeSuiteWhileTheUIDraftIsInvalid() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let committed = store.suite
        store.addCase()
        #expect(store.draftSuite.cases.count == 2)
        #expect(store.suite == committed)

        let authority = MCPStoreAuthority.make(store: store)
        let state = await authority.call(.getState).structuredContent.objectValue!
        let reportedSuite = state["suite"]!.objectValue!
        let workload = state["workload"]!.objectValue!

        #expect(reportedSuite["cases"]?.arrayValue?.count == committed.cases.count)
        #expect(workload["plannedSamples"] == .integer(Int64(committed.cases.count * committed.repetitions)))
        #expect(state["readinessBlocker"] == (
            store.validationIssue(for: committed).map(MCPJSONValue.string) ?? .null
        ))
    }

    @MainActor
    @Test func attachmentToolsAreBoundedAndNaturallyIdempotent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let authority = MCPStoreAuthority.make(store: store)
        let attachmentID = UUID()
        let originalRevision = store.suiteRevision
        let arguments = MCPUploadAttachmentArguments(
            id: attachmentID,
            name: "reference.txt",
            mediaType: "text/plain",
            dataBase64: Data("private body".utf8),
            expectedRevision: originalRevision
        )

        let uploaded = await authority.call(.uploadAttachment(arguments))
        #expect(outcome(uploaded) == "committed")
        let retried = await authority.call(.uploadAttachment(arguments))
        #expect(outcome(retried) == "duplicate")

        let state = await authority.call(.getState).structuredContent.objectValue!
        let attachments = state["attachments"]!.arrayValue!
        #expect(attachments.count == 1)
        #expect(attachments[0].objectValue?["text"] == nil)
        #expect(attachments[0].objectValue?["storedFilename"] == nil)
        let stateText = try MCPJSONValue.object(state).jsonText()
        #expect(!stateText.contains("private body"))
        #expect(!stateText.contains(directory.path))

        let resource = await authority.readResource(.attachment(attachmentID))
        #expect(resource.text == "private body")
        #expect(resource.blob == nil)

        let removed = await authority.call(.removeAttachment(.init(
            id: attachmentID,
            expectedRevision: store.suiteRevision,
            confirm: true
        )))
        #expect(outcome(removed) == "committed")
        let repeatedRemoval = await authority.call(.removeAttachment(.init(
            id: attachmentID,
            expectedRevision: originalRevision,
            confirm: true
        )))
        #expect(outcome(repeatedRemoval) == "duplicate")
    }

    @MainActor
    @Test func runAndHistoryPaginationAreCappedAndReportSkippedSamples() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let evaluationCase = EvaluationCase(name: "Case", prompt: "Prompt", expected: "")
        let run = makeRun(case: evaluationCase, resultCount: 3, plannedCount: 4)
        var older = makeRun(case: evaluationCase, resultCount: 1, plannedCount: 1)
        older.startedAt = run.startedAt.addingTimeInterval(-60)
        older.completedAt = older.startedAt.addingTimeInterval(1)
        store.runs = [run, older]
        let authority = MCPStoreAuthority.make(store: store)

        let first = await authority.call(.getRun(.init(runID: run.id, cursor: nil, limit: 2)))
            .structuredContent.objectValue!["run"]!.objectValue!
        #expect(first["results"]!.arrayValue?.count == 2)
        let cursor = first["nextCursor"]!.stringValue
        #expect(cursor != nil)

        let second = await authority.call(.getRun(.init(runID: run.id, cursor: cursor, limit: 2)))
            .structuredContent.objectValue!["run"]!.objectValue!
        #expect(second["results"]!.arrayValue?.count == 1)
        #expect(second["skipped"]!.arrayValue?.count == 1)
        #expect(second["nextCursor"] == .null)

        let historyFirst = await authority.call(.listRuns(.init(cursor: nil, limit: 1, query: nil, status: nil)))
            .structuredContent.objectValue!
        #expect(historyFirst["runs"]!.arrayValue?.count == 1)
        let historyCursor = historyFirst["nextCursor"]!.stringValue
        let historySecond = await authority.call(.listRuns(.init(cursor: historyCursor, limit: 1, query: nil, status: nil)))
            .structuredContent.objectValue!
        #expect(historySecond["runs"]!.arrayValue?.count == 1)
        #expect(historySecond["nextCursor"] == .null)
    }

    @MainActor
    @Test func cancellationRequestedUsesTheAgentFacingStatusSpelling() throws {
        let operation = EvaluationRunOperation(
            id: UUID(),
            suiteRevision: "revision",
            phase: .cancellationRequested,
            completedSamples: 1,
            totalSamples: 2,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: nil
        )

        let committed = try MCPStoreAuthority.cancellationPayload(previousPhase: .running, operation: operation)
        #expect(outcome(committed) == "committed")
        #expect(committed.structuredContent.objectValue?["status"] == .string("cancellation_requested"))
        #expect(committed.structuredContent.objectValue?["run"]?.objectValue?["phase"] == .string("cancellation_requested"))

        let duplicate = try MCPStoreAuthority.cancellationPayload(
            previousPhase: .cancellationRequested,
            operation: operation
        )
        #expect(outcome(duplicate) == "duplicate")
    }

    @MainActor
    @Test func runResourceIsCanonicalAndDeletionIsDurablyIdempotent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let run = makeRun(
            case: EvaluationCase(name: "Case", prompt: "Prompt", expected: ""),
            resultCount: 1,
            plannedCount: 1
        )
        let canonicalData = try CanonicalJSON.data(for: run)
        let runURL = directory.appending(path: "Runs/\(run.id.uuidString).json")
        try canonicalData.write(to: runURL, options: .atomic)
        store.runs = [run]
        let authority = MCPStoreAuthority.make(store: store)

        let resource = await authority.readResource(.run(run.id))
        #expect(!resource.isError)
        #expect(resource.mimeType == "application/json")
        #expect(resource.text == String(data: canonicalData, encoding: .utf8))
        #expect(resource.blob == nil)

        let deleted = await authority.call(.deleteRun(.init(runID: run.id, confirm: true)))
        #expect(outcome(deleted) == "committed")
        #expect(store.run(with: run.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: runURL.path))

        let duplicate = await authority.call(.deleteRun(.init(runID: run.id, confirm: true)))
        #expect(outcome(duplicate) == "duplicate")
    }

    @MainActor
    @Test func analysisReadsSavedRunsWithoutMutatingSuiteOrStartingModel() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let evaluationCase = EvaluationCase(name: "Case", prompt: "Prompt", expected: "")
        let baseline = makeRun(case: evaluationCase, resultCount: 1, plannedCount: 1)
        var current = baseline
        current.id = UUID()
        store.runs = [current, baseline]
        let revision = store.suiteRevision
        let authority = MCPStoreAuthority.make(store: store)
        let call = try MCPToolCatalog.parse(name: "eval_analyze_run", arguments: .object([
            "runID": .string(current.id.uuidString),
            "baselineRunID": .string(baseline.id.uuidString)
        ]))
        let response = await authority.call(call)
        #expect(!response.isError)
        #expect(response.structuredContent.objectValue?["analysis"] != nil)
        #expect(response.structuredContent.objectValue?["comparison"] != nil)
        #expect(store.suiteRevision == revision)
        #expect(store.activeRun == nil)
        #expect(store.runs.count == 2)

        let unknownBaseline = await authority.call(.analyzeRun(.init(runID: current.id, baselineRunID: UUID())))
        #expect(unknownBaseline.isError)
        let unknownRun = await authority.call(.analyzeRun(.init(runID: UUID(), baselineRunID: nil)))
        #expect(unknownRun.isError)
    }

    @Test func analysisRejectsInvalidIdentifiersAndUnknownOptions() throws {
        for arguments: MCPJSONValue in [
            .object(["runID": .string("invalid")]),
            .object(["runID": .string(UUID().uuidString), "baselineRunID": .integer(1)]),
            .object(["runID": .string(UUID().uuidString), "runModel": .bool(true)])
        ] {
            #expect(throws: MCPToolInputError.self) {
                try MCPToolCatalog.parse(name: "eval_analyze_run", arguments: arguments)
            }
        }
    }

    private func makeRun(case evaluationCase: EvaluationCase, resultCount: Int, plannedCount: Int) -> EvaluationRun {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        return EvaluationRun(
            id: UUID(),
            suiteID: UUID(),
            suiteName: "Suite",
            suiteVersion: "v1",
            instructions: "",
            criteria: "Requirement",
            scoringMode: .review,
            repetitions: plannedCount,
            judgePromptVersion: nil,
            judgePassingScore: nil,
            plannedSampleCount: plannedCount,
            suiteRevision: "revision",
            plannedCases: [evaluationCase],
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(4),
            cancelled: resultCount < plannedCount,
            terminationReason: resultCount < plannedCount ? "cancelled" : nil,
            environment: .init(operatingSystem: "Test", locale: "en_GB", model: "Test", modelContextSize: 4_096),
            attachments: [],
            results: (1...resultCount).map { repetition in
                EvaluationSampleResult(
                    caseID: evaluationCase.id,
                    caseName: evaluationCase.name,
                    repetition: repetition,
                    prompt: evaluationCase.prompt,
                    expected: "",
                    response: "Response \(repetition)",
                    status: .unscored,
                    score: nil,
                    rationale: nil,
                    durationMilliseconds: 1,
                    usage: EvaluationUsage(),
                    judgeDurationMilliseconds: nil,
                    judgeUsage: nil,
                    errorCategory: nil,
                    errorMessage: nil,
                    judgeErrorCategory: nil,
                    judgeErrorMessage: nil
                )
            }
        )
    }

    private func outcome(_ payload: MCPToolPayload) -> String? {
        payload.structuredContent.objectValue?["outcome"]?.stringValue
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MCPStoreAuthorityTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private extension MCPJSONValue {
    var arrayValue: [MCPJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }
}
