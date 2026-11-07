import Foundation
import Testing
@testable import MacIntentTesting

/// Drives the attachment decoder and verdict rules with repeat-level evidence.
struct SiriStudioReportTests {
    private let bundle = "dev.intents.test"
    private let id = UUID(uuidString: "39F7384C-54D1-4524-AD43-363FC48D6DEE")!
    private let first = UUID(uuidString: "55EB5CE9-8F77-4C66-AFB9-C525D75ECA42")!
    private let second = UUID(uuidString: "5C38F116-318C-4B9C-93B5-583DD4799AC9")!

    /// Tests failure precedence over incomplete repeats, then confirms persistence on reopen.
    @Test func failurePrecedesPartialAndBothPersist() throws {
        let scenario = scenario(repeats: 2)
        let digest = try scenario.contentDigest(bundleIdentifier: bundle)
        let partial = try report(digest: digest, index: 1, reached: 1)
        let complete = try report(digest: digest, index: 0, reached: 2)
        let failed = SiriStudioScenarioResult.assess(scenario, bundleIdentifier: bundle, reports: [partial, complete],
            summary: summary(digest, 0.5, rows: [.init(repeatIndex: 0, metrics: ["siriResponseAllPass": 0])]))
        #expect(failed.state == .failed && failed.passed == 0 && failed.failingMetrics == ["siriResponseAllPass"])
        let incomplete = SiriStudioScenarioResult.assess(scenario, bundleIdentifier: bundle, reports: [partial, complete], summary: summary(digest, 0.5))
        #expect(incomplete.state == .incomplete && incomplete.reason == "1 of 2 turns reached.")
        let cancelled = SiriStudioScenarioResult.assess(scenario, bundleIdentifier: bundle, reports: [partial, complete],
            summary: nil, blocked: "Build error", cancelled: "Run cancelled.")
        #expect(cancelled.state == .cancelled)
        let folder = FileManager.default.temporaryDirectory.appending(path: "siri-record-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let record = SiriStudioRunRecord(document: .init(bundleIdentifier: "dev.intents.test", scenarios: [scenario]),
            productIdentity: nil, xcodeBuild: nil, osBuild: "Test", startedAt: .now, endedAt: .now, sourceURL: nil,
            resultBundleURL: nil, logURL: folder.appending(path: "run.log"), scenarios: [failed, incomplete])
        try record.write(to: folder)
        #expect(try SiriStudioRunRecord.read(from: folder).scenarios == [failed, incomplete])
        let export = folder.appending(path: "summary.json")
        try record.exportEvidence(to: export, includeTranscripts: false)
        let exported = try String(contentsOf: export, encoding: .utf8)
        #expect(!exported.contains("fixture utterance") && !exported.contains("fixture response"))
    }

    /// Verifies complete evidence, all-blocked evidence, missing metrics and the aggregate fallback.
    @Test func neverPassesMissingEvidenceAndUsesAggregateFallback() throws {
        let scenario = scenario(repeats: 2)
        let digest = try scenario.contentDigest(bundleIdentifier: bundle)
        let complete = try [report(digest: digest, index: 0, reached: 2), report(digest: digest, index: 1, reached: 2)]
        let setup = try report(digest: digest, index: 0, reached: 0, phase: "setup")
        #expect(SiriStudioScenarioResult.assess(scenario, bundleIdentifier: bundle, reports: complete, summary: summary(digest, 1)).state == .passed)
        #expect(SiriStudioScenarioResult.assess(scenario, bundleIdentifier: bundle, reports: complete, summary: summary(digest, 0.5)).state == .failed)
        #expect(SiriStudioScenarioResult.assess(scenario, bundleIdentifier: bundle, reports: complete, summary: summary(digest, -1)).state == .blocked)
        #expect(SiriStudioScenarioResult.assess(scenario, bundleIdentifier: bundle, reports: complete, summary: nil).state == .blocked)
        #expect(SiriStudioScenarioResult.assess(scenario, bundleIdentifier: bundle, reports: [complete[0], complete[0]], summary: summary(digest, 1)).state == .blocked)
        #expect(SiriStudioScenarioResult.assess(scenario, bundleIdentifier: bundle, reports: [setup], summary: summary(digest, 1)).state == .blocked)
        var evaluatorFailed = summary(digest, 1)
        evaluatorFailed.evaluatorFailureCount = 1
        let missingGrade = SiriStudioScenarioResult.assess(scenario, bundleIdentifier: bundle, reports: complete, summary: evaluatorFailed)
        #expect(missingGrade.state == .blocked && missingGrade.passed == nil)
        let mixed = SiriStudioScenarioResult.assess(scenario, bundleIdentifier: bundle, reports: [setup, complete[1]], summary: summary(digest, 1))
        #expect(mixed.state == .incomplete && mixed.passed == 1 && mixed.attempted == 2)
        #expect(mixed.reports.first?.blocked?.phase == .setup)
        #expect(SiriStudioScenarioResult.assess(scenario, bundleIdentifier: bundle, reports: complete, summary: summary(digest, 1), blocked: "Wrong team").state == .blocked)
    }

    /// Reads an xcresulttool-style manifest, rejects foreign test IDs, and preserves older revisions as stale.
    @Test func importsVersionedAttachmentAndKeepsOlderRevisionStale() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "siri-attachments-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let authored = scenario(repeats: 1)
        let digest = try authored.contentDigest(bundleIdentifier: bundle)
        let transcript = try report(digest: digest, index: 0, reached: 2)
        try JSONEncoder().encode(transcript).write(to: folder.appending(path: "one.json"))
        try JSONEncoder().encode(summary(digest, 1)).write(to: folder.appending(path: "two.json"))
        let token = id.uuidString.replacingOccurrences(of: "-", with: "_")
        let manifest = folder.appending(path: "manifest.json")
        let attachments = [
            ["exportedFileName": "one.json", "suggestedHumanReadableName": "siri-studio-report.json"],
            ["exportedFileName": "two.json", "suggestedHumanReadableName": "siri-studio-summary.json"],
        ]
        let data = try JSONSerialization.data(withJSONObject: [["testIdentifier": "SiriStudioScenarios/scenario_\(token)()", "attachments": attachments]])
        try data.write(to: manifest)
        let evidence = try SiriStudioAttachments.load(from: folder)
        #expect(evidence.result(for: authored, bundleIdentifier: bundle).state == .passed)
        var edited = authored
        edited.revision += 1
        let stale = evidence.result(for: edited, bundleIdentifier: bundle, allowStale: true)
        #expect(stale.revision == 1 && stale.reports == [transcript] && stale.state == .blocked)
        let wrong = try JSONSerialization.data(withJSONObject: [["testIdentifier": "other()", "attachments": attachments]])
        try wrong.write(to: manifest)
        #expect(throws: MacIntentTestingError.self) { try SiriStudioAttachments.load(from: folder) }
    }

    /// A passing bundle cannot grade changed text, changed expectations, or another app at the same revision.
    @Test func rejectsSameRevisionEditsAndUnboundAttachments() throws {
        let authored = scenario(repeats: 1)
        let digest = try authored.contentDigest(bundleIdentifier: bundle)
        let complete = try report(digest: digest, index: 0, reached: 2)
        let evidence = SiriStudioAttachments(reports: [complete], summaries: [summary(digest, 1)])
        var changedUtterance = authored
        changedUtterance.turns[0].utterance = "A different question."
        var changedExpectation = authored
        changedExpectation.turns[0].expectations.replyContains[0].text = "A different expected reply."
        for edited in [changedUtterance, changedExpectation] {
            let result = evidence.result(for: edited, bundleIdentifier: bundle, allowStale: true)
            #expect(result.state == .blocked && result.reports.isEmpty && result.summary == nil)
            #expect(result.reason?.contains("could not verify this scenario's content") == true)
        }
        #expect(evidence.result(for: authored, bundleIdentifier: "dev.intents.other", allowStale: true).state == .blocked)

        let legacy = try report(digest: nil, index: 0, reached: 2)
        let legacyEvidence = SiriStudioAttachments(reports: [legacy], summaries: [summary(nil, 1)])
        #expect(legacyEvidence.result(for: authored, bundleIdentifier: bundle, allowStale: true).state == .blocked)
        let mixed = SiriStudioAttachments(reports: [legacy], summaries: [summary(digest, 1)])
        #expect(mixed.result(for: authored, bundleIdentifier: bundle, allowStale: true).state == .blocked)
    }

    /// Rejects oversized reads and writes at the same byte boundary without replacing earlier evidence.
    @Test func boundsSavedRunRecordSize() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "siri-record-size-\(UUID())")
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: folder) }
        let run = folder.appending(path: "run.json")
        let limit = 64 * 1024 * 1024
        let original = Data("prior evidence".utf8)
        try original.write(to: run)
        var authored = scenario(repeats: 1)
        authored.turns[0].utterance = String(repeating: "x", count: limit)
        let record = SiriStudioRunRecord(document: .init(bundleIdentifier: bundle, scenarios: [authored]),
            productIdentity: nil, xcodeBuild: nil, osBuild: "Test", startedAt: .now, endedAt: .now, sourceURL: nil,
            resultBundleURL: nil, logURL: folder.appending(path: "run.log"), scenarios: [])
        #expect(throws: MacIntentTestingError.self) { try record.write(to: folder) }
        #expect(try Data(contentsOf: run) == original)
        let handle = try FileHandle(forWritingTo: run)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(limit + 1))
        #expect(throws: MacIntentTestingError.self) { try SiriStudioRunRecord.read(from: folder) }
    }

    /// Accepts genuine Swift test assertion failures but rejects skipped or unexecuted selections.
    @Test func verifiesExecutedCountIndependentlyOfPassStatus() throws {
        let counts = #"{"passedTests":1,"failedTests":1,"totalTestCount":2,"skippedTests":0,"expectedFailures":0}"#
        try SiriStudioAttachments.verifyTests(Data(counts.utf8), expectedCount: 2)
        #expect(throws: MacIntentTestingError.self) {
            try SiriStudioAttachments.verifyTests(Data(counts.utf8), expectedCount: 3)
        }
        let skipped = counts.replacingOccurrences(of: #""skippedTests":0"#, with: #""skippedTests":1"#)
        #expect(throws: MacIntentTestingError.self) {
            try SiriStudioAttachments.verifyTests(Data(skipped.utf8), expectedCount: 2)
        }
    }

    /// Ignores unrelated tests in a developer's scheme while retaining skipped Studio cases.
    @Test func importQualifiesOnlyGeneratedTestExecutions() throws {
        let selected = id.uuidString.replacingOccurrences(of: "-", with: "_")
        let skipped = first.uuidString.replacingOccurrences(of: "-", with: "_")
        let cases = [
            ["nodeIdentifier": "AppUITests/other()", "nodeType": "Test Case", "result": "Passed"],
            ["nodeIdentifier": "SiriStudioScenarios/scenario_\(selected)()", "nodeType": "Test Case", "result": "Failed"],
            ["nodeIdentifier": "SiriStudioScenarios/scenario_\(skipped)()", "nodeType": "Test Case", "result": "Skipped"],
        ]
        let tree = try JSONSerialization.data(withJSONObject: ["testNodes": [["nodeType": "Test Suite", "children": cases]]])
        #expect(try SiriStudioAttachments.studioTests(tree) == [id: true, first: false])
    }

    /// Preserves Xcode's original timestamps and OS when importing evidence later.
    @Test func importedFactsUseTheOriginalRun() throws {
        let json = #"{"startTime":123.25,"finishTime":124.5,"devicesAndConfigurations":[{"device":{"osVersion":"27.3","osBuildNumber":"26C"}}]}"#
        let facts = try SiriStudioAttachments.runFacts(Data(json.utf8))
        #expect(facts.started == Date(timeIntervalSince1970: 123.25))
        #expect(facts.ended == Date(timeIntervalSince1970: 124.5))
        #expect(facts.osBuild == "macOS 27.3 (26C)")
    }

    /// Constructs the two-turn scenario shared by the transcript examples.
    private func scenario(repeats: Int) -> SiriStudioScenario {
        .init(id: id, name: "Fixture", repeatCount: repeats, turns: [
            .init(id: first, utterance: "fixture utterance", expectations: .init(replyContains: [.init(text: "fixture response")])),
            .init(id: second, utterance: "fixture follow-up"),
        ])
    }

    /// Decodes the same transcript keys and optional fields emitted by the generated support.
    private func report(digest: String?, index: Int, reached: Int, phase: String? = nil) throws -> SiriStudioReport {
        let turns = [first, second].prefix(reached).map { id -> [String: Any] in
            ["turnID": id.uuidString, "utterance": "fixture utterance", "invocations": [],
             "foundEntities": [], "onScreenEntities": [], "loadedSkills": [],
             "response": ["text": "fixture response", "timestamp": "2026-11-05T12:00:00Z"]]
        }
        var report: [String: Any] = [
            "schema": "dev.intents.siri-studio.report", "version": 1, "scenarioID": id.uuidString, "revision": 1,
            "repeatIndex": index, "status": phase == nil ? "ran" : "blocked", "turnsAuthored": 2,
            "turnsReached": reached, "turns": turns,
        ]
        report["contentDigest"] = digest
        if let phase { report["blocked"] = ["phase": phase, "errorType": "FixtureError", "message": "Setup failed."] }
        return try JSONDecoder().decode(SiriStudioReport.self, from: JSONSerialization.data(withJSONObject: report))
    }

    /// Supplies only Apple's expected reply metric, with optional sample rows.
    private func summary(_ digest: String?, _ value: Double, rows: [SiriStudioSummary.RepeatMetrics]? = nil) -> SiriStudioSummary {
        .init(schema: "dev.intents.siri-studio.summary", version: 1, scenarioID: id, revision: 1, contentDigest: digest,
              metrics: ["siriResponseAllPass": value], perRepeat: rows, inferenceFailureCount: 0, metricsNotFound: [])
    }
}
