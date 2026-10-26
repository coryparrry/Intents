import Foundation
import Observation

@MainActor @Observable
final class EvaluationDocumentDraftController {
    typealias Generator = @Sendable (EvaluationDocumentSource, EvaluationDocumentPassage, String, [String]) async throws -> EvaluationCase?
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
    @ObservationIgnored private let availability: @Sendable () -> String?

    init(directory: URL, projectID: UUID,
         generate: @escaping Generator = EvaluationDocumentGenerator.generate,
         availability: @escaping @Sendable () -> String? = { EvaluationDocumentGenerator.availabilityIssue }) {
        self.projectID = projectID
        self.generateCase = generate
        self.availability = availability
        url = directory.appending(path: "DocumentDrafts/\(projectID.uuidString).json")
        do {
            draft = try EvaluationDocumentDraftStorage.load(from: url)
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
            persist()
        } catch { self.error = error.localizedDescription }
    }

    func generate(retryFailures: Bool = false) {
        guard !isBusy, !storageBlocked, let initial = draft,
              [5, 10, 20].contains(initial.requestedCount), !initial.selectedPassageIDs.isEmpty else { return }
        if let issue = availability() { error = issue; return }
        if retryFailures {
            draft?.completedBatchIDs.subtract(Set(initial.issues.keys))
            draft?.issues = [:]
        }
        guard persist() else { return }
        let id = UUID()
        operationID = id
        isBusy = true
        error = nil
        operation = Task {
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
                    let result = try await generateCase(initial.source, passage,
                        types[slot % types.count], current.cases.map { $0.evaluationCase.prompt })
                    try Task.checkCancellation()
                    guard operationID == id else { break }
                    if let result { draft?.cases.append(.init(evaluationCase: result)) }
                    else { draft?.issues[batchID] = "\(passage.location): no distinct supported question was returned." }
                    draft?.completedBatchIDs.insert(batchID)
                } catch is CancellationError { break }
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
