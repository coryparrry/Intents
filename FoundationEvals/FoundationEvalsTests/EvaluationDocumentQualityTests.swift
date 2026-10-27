import AppKit
import Foundation
import FoundationModels
import PDFKit
import Testing
@testable import FoundationEvals

/// Opt-in live evaluation. Inputs are frozen on disk; every attempt is checkpointed.
@Suite(.serialized)
@MainActor struct EvaluationDocumentQualityTests {
    struct Corpus: Codable { var version: Int; var documents: [Document]; var controls: [Control] }
    struct Document: Codable {
        var id: String; var format: String; var passages: [String]; var requested: Int
        var scannedPages: [Int]?
    }
    struct Control: Codable {
        var id: String; var source: String; var question: String; var reference: String
        var criteria: [String]; var response: String; var shouldPass: Bool
        var expectedRequirementPasses: [Bool]
    }
    struct ControlResult: Codable {
        var control: Control; var score: Int?; var rationale: String?; var status: String
        var trace: EvaluationJudgeTrace?; var identity: EvaluationJudgeIdentity?; var correct: Bool
    }
    struct Attempt: Codable {
        var documentID: String; var slot: Int; var passage: EvaluationDocumentPassage
        var candidate: EvaluationCase?; var issue: String?; var milliseconds: Double
        var outcome: String; var requestedType: String
        var semanticReview: EvaluationDocumentSemanticReview? = nil
    }
    struct Summary: Codable {
        var documents: Int; var requested: Int; var surfaced: Int; var attempts: Int
        var os: String; var generationVersion: String; var judgeVersion: String
        var model: String; var contextSize: Int; var sampling = "greedy"
        var humanReviewComplete: Bool = false
    }

    private func recordRuntime(directory: URL) throws {
        struct Runtime: Encodable { var os: String; var model: String; var contextSize: Int; var sampling = "greedy"; var judgeConfiguration: EvaluationJudgeConnection? }
        let model = SystemLanguageModel.default
        let value = Runtime(os: ProcessInfo.processInfo.operatingSystemVersionString,
            model: model.variant.displayName, contextSize: model.contextSize, judgeConfiguration: try judgeConfiguration())
        let url = directory.appending(path: "runtime.json")
        let data = try CanonicalJSON.data(for: value)
        if FileManager.default.fileExists(atPath: url.path) {
            try #require(Data(contentsOf: url) == data, "Runtime identity must match the existing evidence.")
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    private func judgeConfiguration() throws -> EvaluationJudgeConnection? {
        guard let path = ProcessInfo.processInfo.environment["INTENTS_DOCUMENT_QUALITY_JUDGE_CONFIG"] else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(EvaluationJudgeConnection.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    /// Only an explicitly opted-in synthetic run supplies a connection here.
    static func controlSuite(value: EvaluationCase, connection: EvaluationJudgeConnection?) -> EvaluationSuite {
        var suite = EvaluationSuite()
        suite.cases = [value]
        suite.modelConfiguration.contextPolicy = .requireFullInput
        if let connection {
            suite.judgeConfiguration = .init(mode: .connection, connectionID: connection.id,
                externalEvidenceApprovedAt: Date(), includeReferenceAttachments: false,
                approvedConnectionID: connection.id, approvedIncludeReferenceAttachments: false,
                approvedConnectionDigest: connection.disclosureDigest,
                approvedEvidencePolicyVersion: EvaluationJudgeConfiguration.currentEvidencePolicyVersion)
        }
        return suite
    }

    private func input() throws -> Corpus {
        let path = try #require(ProcessInfo.processInfo.environment["INTENTS_DOCUMENT_QUALITY_CORPUS"])
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
    private func output() throws -> URL {
        let path = try #require(ProcessInfo.processInfo.environment["INTENTS_DOCUMENT_QUALITY_OUTPUT"])
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func append<T: Encodable>(_ value: T, name: String, directory: URL) throws {
        let url = directory.appending(path: name)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var data = try CanonicalJSON.data(for: value, prettyPrinted: false)
        data.append(10)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["INTENTS_DOCUMENT_QUALITY_CORPUS"] != nil))
    func controlledAnswersHaveCorrectRequirementScores() async throws {
        let corpus = try input(), directory = try output()
        try #require(!FileManager.default.fileExists(atPath: directory.appending(path: "controls.jsonl").path), "Use a fresh output directory; earlier controls must not be mixed into this run.")
        try recordRuntime(directory: directory)
        let model = SystemLanguageModel.default
        let external: EvaluationResolvedJudgeConnection?
        if let connection = try judgeConfiguration() {
            let key = try EvaluationJudgeCredentialStore.load(connection: connection)
            try #require(key != nil || connection.kind == .localCompatible,
                "The selected external judge needs its configured Keychain credential.")
            external = .init(connection: connection, apiKey: key)
        } else { external = nil }
        if external == nil { try #require(EvaluationDocumentGenerator.availabilityIssue == nil) }
        for control in corpus.controls {
            let passage = EvaluationDocumentPassage(id: "control", location: "Control source", text: control.source)
            var value = EvaluationCase(name: control.id, prompt: control.question, expected: control.reference)
            value.criteriaOverride = control.criteria
            value.documentEvidence = .init(sourceName: "control.txt", sourceDigest: EvaluationDocumentEvidence.digest(Data(control.source.utf8)),
                passages: [passage], citations: [.init(passageID: passage.id, quote: control.source)], questionType: "Calibration")
            value.acceptDocumentReview()
            let suite = Self.controlSuite(value: value, connection: external?.connection)
            let effective = suite.effectiveSuite(for: value)
            let runner = EvaluationRunner()
            let result = await runner.score(response: control.response, evaluationCase: value,
                effectivePrompt: control.question + "\n\nSource context:\n" + control.source,
                suite: effective, runID: UUID(), images: [], model: model, contextSize: model.contextSize,
                modelName: model.variant.displayName, externalJudge: external, toolEvidence: nil,
                tokenCounter: EvaluationSystemPromptInputTokenCounter())
            let requirementPasses = result.trace?.checks?.sorted { $0.criterionIndex < $1.criterionIndex }.map { $0.score >= 3 }
            let correct = (result.status == .passed) == control.shouldPass
                && result.score != nil && requirementPasses == control.expectedRequirementPasses
            try append(ControlResult(control: control, score: result.score, rationale: result.rationale,
                status: String(describing: result.status), trace: result.trace, identity: result.identity, correct: correct), name: "controls.jsonl", directory: directory)
            #expect(correct, "Control \(control.id): \(result.rationale ?? "No assessment")")
            print("DOCUMENT_QUALITY_CONTROL \(control.id) correct=\(correct)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["INTENTS_DOCUMENT_QUALITY_CORPUS"] != nil))
    func frozenCorpusGenerationRecordsEveryAttempt() async throws {
        let corpus = try input(), directory = try output()
        for name in ["attempts.jsonl", "sources.jsonl", "summary.json", "corpus.json"] {
            try #require(!FileManager.default.fileExists(atPath: directory.appending(path: name).path), "Use a fresh output directory; earlier generation evidence must be preserved separately.")
        }
        try recordRuntime(directory: directory)
        try CanonicalJSON.data(for: corpus).write(to: directory.appending(path: "corpus.json"), options: .atomic)
        try #require(EvaluationDocumentGenerator.availabilityIssue == nil)
        let reviewer = try await EvaluationDocumentSemanticReviewer.configured(try judgeConfiguration())
        var surfaced = 0, totalAttempts = 0
        for document in corpus.documents {
            let sourceURL = try materialize(document, directory: directory)
            let source = try EvaluationDocumentImporter.importFile(at: sourceURL)
            try append(source, name: "sources.jsonl", directory: directory)
            var cases: [EvaluationCase] = []
            let count = document.requested * 2
            for slot in 0..<count {
                if cases.count >= document.requested { break }
                let index = source.passages.count >= count ? slot * source.passages.count / count : slot % source.passages.count
                let passage = source.passages[index]
                let started = ContinuousClock.now
                var candidate: EvaluationCase?, issue: String?
                var semanticReview: EvaluationDocumentSemanticReview?
                var stopDocument = false
                var outcome = "runtime_failure"
                let requestedType = ["Direct fact", "Apply a rule", "Limit or exception"][slot % 3]
                do {
                    let reviewed = try await EvaluationDocumentDraftPipeline.generate(source: source, passage: passage,
                        questionType: requestedType, existingQuestions: cases.map(\.prompt), batchID: "\(document.id):\(slot)",
                        reviewer: reviewer) { attempt in
                            try append(attempt, name: "semantic-attempts.jsonl", directory: directory)
                        }
                    candidate = reviewed.candidate
                    semanticReview = reviewed.review
                    if let value = candidate, let budgetIssue = EvaluationSuite.documentContextBudgetIssue(for: cases + [value]) {
                        candidate = nil; outcome = "suite_budget_rejection"; issue = budgetIssue
                    } else if let value = candidate, EvaluationDocumentGenerator.repeatsFact(value, among: cases) {
                        candidate = nil; outcome = "duplicate"; issue = "The same source fact already exists"
                    } else if candidate != nil { outcome = "surfaced" }
                    else { outcome = "semantic_rejection_or_unsupported"; issue = "No approved draft within the attempt limit" }
                } catch let failure as EvaluationDocumentDraftPipeline.ReviewUnavailable {
                    issue = failure.localizedDescription; outcome = "semantic_review_error"; stopDocument = true
                } catch { issue = error.localizedDescription }
                let elapsed = started.duration(to: .now)
                let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
                try append(Attempt(documentID: document.id, slot: slot, passage: passage, candidate: candidate,
                    issue: issue, milliseconds: ms, outcome: outcome, requestedType: requestedType, semanticReview: semanticReview), name: "attempts.jsonl", directory: directory)
                totalAttempts += 1
                if let candidate { cases.append(candidate); surfaced += 1 }
                if outcome == "suite_budget_rejection" || stopDocument { break }
            }
            print("DOCUMENT_QUALITY_YIELD \(document.id) surfaced=\(cases.count) requested=\(document.requested)")
        }
        let summary = Summary(documents: corpus.documents.count, requested: corpus.documents.reduce(0) { $0 + $1.requested },
            surfaced: surfaced, attempts: totalAttempts, os: ProcessInfo.processInfo.operatingSystemVersionString,
            generationVersion: EvaluationDocumentGenerator.version, judgeVersion: EvaluationRunner.judgePromptVersion,
            model: SystemLanguageModel.default.variant.displayName, contextSize: SystemLanguageModel.default.contextSize)
        try CanonicalJSON.data(for: summary).write(to: directory.appending(path: "summary.json"), options: .atomic)
        #expect(corpus.documents.count >= 10)
        #expect(surfaced >= 100, "At least 100 surfaced drafts are required before evaluating the percentage gates.")
    }

    struct FocusCase: Codable {
        var id: String
        var source: EvaluationDocumentSource
        var passage: EvaluationDocumentPassage
        var requestedType: String
        var existingQuestions: [String]
        var requiredTerms: [String]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["INTENTS_DOCUMENT_QUALITY_CORPUS"] != nil))
    func focusedGenerationRegressions() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["INTENTS_DOCUMENT_QUALITY_CORPUS"])
        let fixtures = try JSONDecoder().decode([FocusCase].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let directory = try output()
        try recordRuntime(directory: directory)
        let reviewer = try await EvaluationDocumentSemanticReviewer.configured(try judgeConfiguration())
        for fixture in fixtures {
            do {
                let reviewed = try await EvaluationDocumentDraftPipeline.generate(source: fixture.source, passage: fixture.passage,
                    questionType: fixture.requestedType, existingQuestions: fixture.existingQuestions, batchID: fixture.id,
                    reviewer: reviewer) { attempt in try append(attempt, name: "semantic-attempts.jsonl", directory: directory) }
                let candidate = reviewed.candidate
                try append(Attempt(documentID: fixture.id, slot: 0, passage: fixture.passage, candidate: candidate,
                    issue: nil, milliseconds: 0, outcome: candidate == nil ? "rejected" : "surfaced",
                    requestedType: fixture.requestedType, semanticReview: reviewed.review), name: "attempts.jsonl", directory: directory)
                let value = try #require(candidate, "Known supported focus must yield an approved draft: \(fixture.id)")
                #expect(reviewed.review?.matches(value) == true)
                let text = (value.prompt + " " + value.expected).lowercased()
                for term in fixture.requiredTerms { #expect(text.contains(term), "Missing scope: \(fixture.id) / \(term)") }
                if fixture.id == "editor-shortcuts:4" {
                    // This source defines intentionally disabled autosave, not a failed attempt.
                    #expect(!value.prompt.lowercased().contains("fail"), "Read-only autosave must not be described as a failure")
                }
            } catch {
                Issue.record("Focused generation failed for \(fixture.id): \(error)")
            }
        }
    }

    struct SemanticControl: Codable {
        var id: String
        var source: EvaluationDocumentSource
        var candidate: EvaluationCase
        var accepted: Bool
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["INTENTS_DOCUMENT_QUALITY_CORPUS"] != nil))
    func semanticControlsRejectBadDrafts() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["INTENTS_DOCUMENT_QUALITY_CORPUS"])
        let fixtures = try CanonicalJSON.decode([SemanticControl].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try await reviewSemanticControls(fixtures)
    }

    struct RegressionCorpus: Decodable {
        struct Control: Decodable {
            struct Citation: Decodable { var passageID: String; var quote: String }
            var id: String; var sourceID: String; var question: String; var reference: String
            var citations: [Citation]; var existingQuestions: [String]; var accepted: Bool
        }
        var sources: [String: EvaluationDocumentSource]
        var controls: [Control]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["INTENTS_DOCUMENT_QUALITY_CORPUS"] != nil))
    func knownFalseApprovalsAreRejected() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["INTENTS_DOCUMENT_ACCEPTANCE_CORPUS"])
        let corpus = try CanonicalJSON.decode(RegressionCorpus.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let directory = try output()
        try recordRuntime(directory: directory)
        let reviewer = try await EvaluationDocumentSemanticReviewer.configured(try judgeConfiguration())
        struct Result: Encodable { var id: String; var expectedAcceptance: Bool; var candidate: EvaluationCase; var review: EvaluationDocumentSemanticReview; var correct: Bool }
        for control in corpus.controls {
            let source = try #require(corpus.sources[control.sourceID])
            var candidate = EvaluationCase(name: control.id, prompt: control.question, expected: control.reference)
            candidate.criteriaOverride = [EvaluationDocumentGenerator.criterion(for: control.reference, question: control.question)]
            candidate.documentEvidence = .init(sourceName: source.name, sourceDigest: source.fileDigest,
                passages: source.passages, citations: control.citations.map { .init(passageID: $0.passageID, quote: $0.quote) }, questionType: "Direct fact")
            let review = try await reviewer(candidate, source, control.existingQuestions)
            let correct = review.matches(candidate) == control.accepted
            try append(Result(id: control.id, expectedAcceptance: control.accepted, candidate: candidate, review: review, correct: correct), name: "acceptance-controls.jsonl", directory: directory)
            #expect(correct, "Historical false-approval control \(control.id): \(review.feedback)")
        }
    }

    private func reviewSemanticControls(_ fixtures: [SemanticControl]) async throws {
        let directory = try output()
        try recordRuntime(directory: directory)
        let reviewer = try await EvaluationDocumentSemanticReviewer.configured(try judgeConfiguration())
        struct Result: Encodable { var id: String; var expectedAcceptance: Bool; var review: EvaluationDocumentSemanticReview; var correct: Bool }
        for fixture in fixtures {
            let review = try await reviewer(fixture.candidate, fixture.source, [])
            let correct = review.matches(fixture.candidate) == fixture.accepted
            try append(Result(id: fixture.id, expectedAcceptance: fixture.accepted, review: review, correct: correct), name: "semantic-controls.jsonl", directory: directory)
            #expect(correct, "Semantic control \(fixture.id): \(review.feedback)")
        }
    }

    private func materialize(_ document: Document, directory: URL) throws -> URL {
        let url = directory.appending(path: document.id + "." + document.format)
        if document.format == "pdf" {
            let pdf = PDFDocument()
            for (index, text) in document.passages.enumerated() {
                let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 700))
                view.font = .systemFont(ofSize: 13)
                view.string = text
                let pageData: Data
                if document.scannedPages?.contains(index) == true {
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let image = NSImage(size: view.bounds.size)
                    image.addRepresentation(bitmap)
                    let imageView = NSImageView(frame: view.bounds)
                    imageView.image = image
                    pageData = imageView.dataWithPDF(inside: imageView.bounds)
                } else { pageData = view.dataWithPDF(inside: view.bounds) }
                let page = try #require(PDFDocument(data: pageData)?.page(at: 0))
                pdf.insert(page, at: pdf.pageCount)
            }
            try #require(pdf.dataRepresentation()).write(to: url)
        } else {
            try Data(document.passages.joined(separator: "\n\n").utf8).write(to: url)
        }
        return url
    }
}
