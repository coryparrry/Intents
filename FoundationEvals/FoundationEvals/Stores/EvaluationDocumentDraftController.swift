import Foundation
import Observation

@MainActor @Observable
final class EvaluationDocumentDraftController {
    typealias Generator = EvaluationDocumentDraftPipeline.Generator
    var draft: EvaluationDocumentDraft?
    var error: String?
    var progress = ""
    var isBusy = false
    var storageBlocked = false
    @ObservationIgnored private let url: URL
    @ObservationIgnored private let projectID: UUID
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private let generateCase: Generator
    @ObservationIgnored private let reviewerFactory: EvaluationDocumentSemanticReviewer.Factory
    @ObservationIgnored private let availability: @Sendable () -> String?

    init(directory: URL, projectID: UUID,
         generate: @escaping Generator = EvaluationDocumentGenerator.generate,
         reviewerFactory: @escaping EvaluationDocumentSemanticReviewer.Factory = EvaluationDocumentSemanticReviewer.configured,
         availability: @escaping @Sendable () -> String? = { EvaluationDocumentGenerator.availabilityIssue }) {
        self.projectID = projectID
        self.generateCase = generate
        self.availability = availability
        self.reviewerFactory = reviewerFactory
        url = directory.appending(path: "DocumentDrafts/\(projectID.uuidString).json")
        do {
            draft = try EvaluationDocumentDraftStorage.load(from: url)
            draft?.requiresSemanticReview = true
            if let draft, draft.projectID != projectID { throw EvaluationStoreError.persistence("The saved draft belongs to another project.") }
        } catch {
            self.error = error.localizedDescription
            storageBlocked = true
        }
    }

    func importFile(_ file: URL, selection: ClosedRange<Int>?) {
        guard !isBusy, !storageBlocked, draft == nil else { return }
        let id = UUID()
        operationID = id
        isBusy = true
        error = nil
        progress = "Extracting document text…"
        operation = Task {
            let extraction = Task.detached { try EvaluationDocumentImporter.importFile(at: file, selection: selection) }
            do {
                let source = try await withTaskCancellationHandler {
                    try await extraction.value
                } onCancel: { extraction.cancel() }
                try Task.checkCancellation()
                guard operationID == id else { return }
                draft = .init(projectID: projectID, name: file.deletingPathExtension().lastPathComponent,
                    source: source, selectedPassageIDs: Set(source.passages.map(\.id)))
                draft?.requiresSemanticReview = true
                persist()
            } catch is CancellationError {
                // Completed draft data is retained by cancellation; an incomplete extraction is discarded.
            } catch { if operationID == id { self.error = error.localizedDescription } }
            if operationID == id { isBusy = false; operation = nil; progress = "" }
        }
    }

    func importArchive(_ file: URL) {
        guard !isBusy, !storageBlocked, draft == nil else { return }
        let accessed = file.startAccessingSecurityScopedResource()
        defer { if accessed { file.stopAccessingSecurityScopedResource() } }
        do {
            let data = try EvaluationAttachmentStorage.readCaseImportFile(at: file, maximumBytes: EvaluationDocumentDraftStorage.maximumBytes)
            draft = try EvaluationDocumentArchive.draft(from: data, projectID: projectID)
            draft?.requiresSemanticReview = true
            persist()
        } catch { self.error = error.localizedDescription }
    }

    func generate(retryFailures: Bool = false, judge: EvaluationJudgeConnection? = nil) {
        guard !isBusy, !storageBlocked, let initial = draft,
              [5, 10, 20].contains(initial.requestedCount), !initial.selectedPassageIDs.isEmpty else { return }
        if let issue = availability() { error = issue; return }
        do {
            if let judge {
                guard initial.semanticJudgeID == judge.id, initial.semanticApprovalDigest == judge.disclosureDigest else {
                    throw EvaluationStoreError.invalidSuite("Authorize the selected semantic judge before sending document text.")
                }
            }
        } catch { self.error = error.localizedDescription; return }
        draft?.requiresSemanticReview = true
        draft?.generationVersion = EvaluationDocumentGenerator.version
        guard persist() else { return }
        let id = UUID()
        operationID = id
        isBusy = true
        error = nil
        operation = Task {
            let reviewer: EvaluationDocumentSemanticReviewer.Reviewer
            do {
                reviewer = try await reviewerFactory(judge)
                try Task.checkCancellation()
                guard operationID == id else { return }
                if retryFailures {
                    draft?.completedBatchIDs.subtract(Set(initial.issues.keys))
                    draft?.issues = [:]
                    guard persist() else { isBusy = false; operation = nil; progress = ""; return }
                }
            } catch {
                if operationID == id { self.error = error.localizedDescription; isBusy = false; operation = nil; progress = "" }
                return
            }
            let passages = initial.source.passages.filter { initial.selectedPassageIDs.contains($0.id) }
            let types = ["Direct fact", "Apply a rule", "Limit or exception"]
            // Spread a bounded number of attempts across the entire selection, not just its beginning.
            let attemptCount = initial.requestedCount * 2
            for slot in 0..<attemptCount {
                guard !Task.isCancelled, operationID == id, let current = draft else { break }
                if current.cases.filter({ !$0.discarded }).count >= initial.requestedCount { break }
                let index = passages.count >= attemptCount
                    ? min(passages.count - 1, slot * passages.count / attemptCount) : slot % passages.count
                let passage = passages[index]
                let batchID = "\(passage.id):\(slot)"
                if current.completedBatchIDs.contains(batchID) || current.issues[batchID] != nil { continue }
                progress = "Drafting from \(passage.location) · attempt \(slot + 1) of \(attemptCount)"
                do {
                    let reviewed = try await EvaluationDocumentDraftPipeline.generate(source: initial.source, passage: passage,
                        questionType: types[slot % types.count], existingQuestions: current.cases.filter { !$0.discarded }.map { $0.evaluationCase.prompt },
                        batchID: batchID, generator: generateCase, reviewer: reviewer) { [self] attempt in
                            guard operationID == id, !Task.isCancelled else { throw CancellationError() }
                            if draft?.semanticAttempts == nil { draft?.semanticAttempts = [] }
                            draft?.semanticAttempts?.append(attempt)
                            if ["rejected", "validation_rejected"].contains(attempt.outcome), attempt.attempt < EvaluationDocumentDraftPipeline.maximumAttempts {
                                progress = "Draft rejected; correcting and rechecking (\(attempt.attempt + 1) of \(EvaluationDocumentDraftPipeline.maximumAttempts))…"
                            }
                            guard persist() else { throw EvaluationStoreError.persistence(error ?? "Could not save semantic review.") }
                        }
                    let result = reviewed.candidate
                    try Task.checkCancellation()
                    guard operationID == id else { break }
                    if let result, let issue = EvaluationSuite.documentContextBudgetIssue(for:
                        current.cases.filter { !$0.discarded }.map(\.evaluationCase) + [result]) {
                        draft?.issues[batchID] = "\(passage.location): \(issue) The completed drafts remain usable."
                        persist()
                        break
                    }
                    if let result, !EvaluationDocumentGenerator.repeatsFact(result,
                        among: current.cases.filter { !$0.discarded }.map(\.evaluationCase)) {
                        draft?.cases.append(.init(evaluationCase: result, semanticReview: reviewed.review))
                    }
                    else { draft?.issues[batchID] = "\(passage.location): no distinct supported question was returned." }
                    draft?.completedBatchIDs.insert(batchID)
                } catch is CancellationError { break }
                catch let failure as EvaluationDocumentDraftPipeline.ReviewUnavailable {
                    guard operationID == id else { break }
                    draft?.issues[batchID] = failure.localizedDescription
                    self.error = failure.localizedDescription
                    persist()
                    break
                }
                catch {
                    guard operationID == id else { break }
                    draft?.issues[batchID] = "\(passage.location): \(error.localizedDescription)"
                    if availability() != nil { persist(); break }
                }
                guard persist() else { break }
            }
            if operationID == id { isBusy = false; operation = nil; progress = "Draft progress saved. Review each question against its source." }
        }
    }

    func reviewAndAccept(caseID: UUID, judge: EvaluationJudgeConnection?) {
        guard !isBusy, !storageBlocked, let current = draft,
              let item = current.cases.first(where: { $0.id == caseID }) else { return }
        if current.semanticReviewIsCurrent(for: caseID) {
            if let index = draft?.cases.firstIndex(where: { $0.id == caseID }) { draft?.cases[index].evaluationCase.acceptDocumentReview() }
            persist()
            return
        }
        do {
            guard let judge, current.semanticJudgeID == judge.id, current.semanticApprovalDigest == judge.disclosureDigest else {
                throw EvaluationStoreError.invalidSuite("Authorize a semantic judge to check the edited draft.")
            }
        } catch { self.error = error.localizedDescription; return }
        let id = UUID()
        operationID = id; isBusy = true; error = nil; progress = "Checking the edited draft against its source…"
        operation = Task {
            do {
                let reviewer = try await reviewerFactory(judge)
                try Task.checkCancellation()
                guard operationID == id else { return }
                var source = current.source
                if current.importedTemplate != nil, let evidence = item.evaluationCase.documentEvidence {
                    source = .init(name: evidence.sourceName, fileDigest: evidence.sourceDigest, passages: evidence.passages)
                }
                let review = try await reviewer(item.evaluationCase, source,
                    current.cases.filter { $0.id != caseID && !$0.discarded }.map { $0.evaluationCase.prompt })
                try Task.checkCancellation()
                guard operationID == id, let index = draft?.cases.firstIndex(where: { $0.id == caseID }),
                      draft?.cases[index].evaluationCase.documentReviewDigest == item.evaluationCase.documentReviewDigest else { return }
                draft?.requiresSemanticReview = true
                draft?.cases[index].semanticReview = review
                if review.matches(item.evaluationCase) { draft?.cases[index].evaluationCase.acceptDocumentReview() }
                else { self.error = "Draft rejected: " + review.feedback }
                persist()
            } catch { if operationID == id { self.error = error.localizedDescription } }
            if operationID == id { isBusy = false; operation = nil; progress = "" }
        }
    }

    func cancel() {
        operation?.cancel()
        operationID = nil
        operation = nil
        isBusy = false
        progress = "Stopped. Completed drafts and edits are saved."
        persist()
    }

    /// A completion signal for tests and callers that need durable batch completion, without polling UI state.
    func waitUntilIdle() async { await operation?.value }

    @discardableResult func persist() -> Bool {
        guard !storageBlocked else { return false }
        guard let draft else { return true }
        do { try EvaluationDocumentDraftStorage.save(draft, to: url); return true }
        catch { self.error = "Could not save draft: \(error.localizedDescription)"; return false }
    }

    func discard() {
        cancel()
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            draft = nil; error = nil; storageBlocked = false; progress = ""
        } catch { self.error = error.localizedDescription }
    }
}
