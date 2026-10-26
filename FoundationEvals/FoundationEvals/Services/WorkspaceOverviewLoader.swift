import Foundation

actor WorkspaceOverviewLoader {
    /// Loads summaries for active project suites without moving draft recovery files or admitting uncommitted pending runs.
    /// Cancellation returns an empty result; unreadable suite evidence becomes an unavailable summary with a storage notice.
    func load(project: EvaluationProject, directory: URL) async -> [SuiteOverviewSummary] {
        var summaries: [SuiteOverviewSummary] = []
        for record in project.suites where !record.isArchived {
            guard !Task.isCancelled else { return [] }
            var summary = SuiteOverviewSummary(record: record)
            do {
                let root = EvaluationWorkspacePersistence.suiteDirectory(
                    supportDirectory: directory, projectID: project.id, suiteID: record.id
                )
                let suite = try CanonicalJSON.decode(
                    EvaluationSuite.self, from: Data(contentsOf: root.appending(path: "suite.json"))
                )
                guard suite.id == record.id else { throw EvaluationWorkspaceError.missingSuite }
                let revision = try EvaluationStore.revision(for: suite)
                let draftURL = root.appending(path: "suite-draft.json")
                let savedDraft = try optional(Draft.self, at: draftURL)
                // Match the editor's recovery contract without moving recovery
                // files while loading a background overview.
                let draft = savedDraft.flatMap {
                    $0.suite.id == suite.id && $0.canonicalRevision == revision ? $0.suite : nil
                }
                let local = try optional(EvaluationSuiteLocalState.self, at: root.appending(path: "state.json"))
                    ?? EvaluationSuiteLocalState()
                let pending = try optional(PendingRuns.self, at: root.appending(path: "pending-completed-runs.json"))
                let pendingRunIDs = Set(pending?.runs.map(\.id) ?? [])
                let urls = try FileManager.default.contentsOfDirectory(
                    at: root.appending(path: "Runs"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                ).filter { $0.pathExtension == "json" }
                var runs: [EvaluationRun] = []
                for url in urls {
                    try Task.checkCancellation()
                    let run = try CanonicalJSON.decode(EvaluationRun.self, from: Data(contentsOf: url))
                    guard url.deletingPathExtension().lastPathComponent == run.id.uuidString,
                          run.suiteID == record.id,
                          run.projectID == nil || run.projectID == project.id else {
                        continue
                    }
                    // A failed multi-run save may have published only part of
                    // its history. Admit those records after the retry commits.
                    if !pendingRunIDs.contains(run.id) { runs.append(run) }
                }
                summary = SuiteOverviewSummary(record: record, suite: suite, currentRevision: revision,
                                                     draft: draft, runs: runs, localState: local)
                if let definitionURL = EvaluationWorkspacePersistence.repositoryDefinitionURL(project: project, suite: record) {
                    let definition = try CanonicalJSON.decode(EvaluationSuiteDefinition.self, from: Data(contentsOf: definitionURL))
                    guard definition.id == suite.id, definition.formatVersion == EvaluationSuiteDefinition.currentFormatVersion else {
                        throw EvaluationWorkspaceError.repositoryConflict
                    }
                    let repositoryRevision = try EvaluationWorkspacePersistence.definitionRevision(definition)
                    if repositoryRevision != record.lastRepositoryRevision {
                        summary.repositoryChanged = true
                        summary.state = .changed
                    }
                }
            } catch is CancellationError {
                return []
            } catch {
                summary.state = .unavailable
                summary.loadError = "Saved data could not be read. Open this suite to review the storage notice."
            }
            summaries.append(summary)
        }
        return summaries
    }

    /// Decodes an optional saved JSON value, returning nil only for a missing file and propagating all other read or decoding failures.
    private func optional<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        do { return try CanonicalJSON.decode(type, from: Data(contentsOf: url)) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }

    private struct PendingRuns: Decodable { var runs: [EvaluationRun] }
    private struct Draft: Decodable {
        var canonicalRevision: String
        var suite: EvaluationSuite
    }
}
