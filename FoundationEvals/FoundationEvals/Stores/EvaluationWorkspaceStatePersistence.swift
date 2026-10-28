import CryptoKit
import Foundation

/// A content-free failure returned independently of user-facing recovery notices.
enum EvaluationWorkspaceLoadFailure: Sendable {
    case storage
}

enum EvaluationWorkspaceStatePersistence {
    /// Loads canonical suite JSON and optionally checks its workspace identity.
    /// Returns a typed storage failure for unreadable or mismatched data. Missing storage returns no suite; unreadable or mismatched bytes are backed up when possible, with a write blocker if preservation fails.
    static func loadSuite(from directory: URL, expectedSuiteID: UUID? = nil)
        -> (suite: EvaluationSuite?, notice: String?, persistenceBlocker: String?, failure: EvaluationWorkspaceLoadFailure?) {
        let url = directory.appending(path: "suite.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, nil, nil, nil) }
        do {
            let data = try Data(contentsOf: url)
            let suite = try CanonicalJSON.decode(EvaluationSuite.self, from: data)
            if let expectedSuiteID, suite.id != expectedSuiteID {
                let preservation = preserveUnreadableFile(at: url, prefix: "suite-mismatched")
                let suffix = preservation.map { " It was preserved as \($0)." } ?? ""
                return (nil, "The saved suite belongs to a different workspace suite.\(suffix)",
                        preservation == nil ? suitePreservationBlocker : nil, .storage)
            }
            return (suite, nil, nil, nil)
        } catch {
            let preservation = preserveUnreadableFile(at: url, prefix: "suite-unreadable")
            let suffix = preservation.map { " It was preserved as \($0)." } ?? ""
            return (nil, "The saved suite could not be read.\(suffix)",
                    preservation == nil ? suitePreservationBlocker : nil, .storage)
        }
    }

    private static let suitePreservationBlocker =
        "The saved suite could not be preserved. Resolve the storage conflict and reopen the app before saving workspace changes."

    /// Loads local approvals and reviews, returning empty state for missing or unreadable storage.
    /// Returns typed failures independently of notices. Optionally preserves unreadable bytes and reports a blocker when that preservation fails; missing migrated state produces a recovery notice.
    static func loadSuiteLocalState(
        from url: URL,
        preserveUnreadable: Bool = true
    ) -> (state: EvaluationSuiteLocalState, notice: String?, persistenceBlocker: String?, failure: EvaluationWorkspaceLoadFailure?) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let migrated = EvaluationWorkspacePersistence.hasCompletedLegacyStateMigration(
                in: url.deletingLastPathComponent()
            )
            return (
                EvaluationSuiteLocalState(),
                migrated ? "The saved suite state is missing after migration. Legacy approvals were not restored; review the suite state before release." : nil,
                nil,
                migrated ? .storage : nil
            )
        }
        do {
            let data = try Data(contentsOf: url)
            return (try CanonicalJSON.decode(EvaluationSuiteLocalState.self, from: data), nil, nil, nil)
        } catch {
            let preservation = preserveUnreadable
                ? preserveUnreadableFile(at: url, prefix: "state-unreadable")
                : nil
            let suffix = preservation.map { " It was preserved as \($0)." } ?? ""
            let blocker = preserveUnreadable && preservation == nil
                ? "The unreadable suite state could not be preserved. Restore file access or resolve the conflicting state-unreadable backup, then select a suite again or reopen Intents to retry. Saved approvals and reviews will not be overwritten."
                : nil
            return (
                EvaluationSuiteLocalState(),
                blocker ?? "The saved suite state could not be read.\(suffix)",
                blocker,
                .storage
            )
        }
    }

    /// Loads judge metadata or returns an empty list and recovery notice when unreadable bytes cannot be decoded.
    /// Returns a typed storage failure and attempts to preserve damaged metadata before later replacement.
    static func loadJudgeConnections(
        from url: URL
    ) -> (connections: [EvaluationJudgeConnection], notice: String?, failure: EvaluationWorkspaceLoadFailure?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], nil, nil) }
        do {
            let data = try Data(contentsOf: url)
            return (try CanonicalJSON.decode([EvaluationJudgeConnection].self, from: data), nil, nil)
        } catch {
            let preservation = preserveUnreadableFile(
                at: url, prefix: "judge-connections-unreadable"
            )
            let suffix = preservation.map { " It was preserved as \($0)." } ?? ""
            return ([], "The saved judge connections could not be read.\(suffix)", .storage)
        }
    }

    /// A failed startup archive must not turn the next save into deletion of
    /// the only recoverable copy. Recheck at the write boundary so a repaired
    /// archive/storage conflict can be retried without replacing the workspace.
    static func preserveUnreadableBeforeReplacing<Value: Decodable>(
        at url: URL,
        as type: Value.Type,
        prefix: String
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        do {
            _ = try CanonicalJSON.decode(type, from: data)
        } catch {
            try EvaluationWorkspacePersistence.preserveUnreadableFile(
                data, in: url.deletingLastPathComponent(), prefix: prefix
            )
        }
    }

    /// Preserves original bytes in a digest-named regular backup without changing the source.
    /// Reuses an identical nonsymlink backup; returns its filename on success or nil for unreadable/conflicting storage.
    private static func preserveUnreadableFile(at url: URL, prefix: String) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let filename = "\(prefix)-\(digest).json"
        let backup = url.deletingLastPathComponent()
            .appending(path: filename, directoryHint: .notDirectory)
        if FileManager.default.fileExists(atPath: backup.path) {
            guard let values = try? backup.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  (try? Data(contentsOf: backup)) == data else { return nil }
            return filename
        }
        guard (try? data.write(to: backup, options: .atomic)) != nil else { return nil }
        return filename
    }
}
