import CryptoKit
import Foundation

enum EvaluationWorkspaceStatePersistence {
    static func loadSuite(from directory: URL) -> (suite: EvaluationSuite?, notice: String?) {
        let url = directory.appending(path: "suite.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, nil) }
        do {
            let data = try Data(contentsOf: url)
            return (try CanonicalJSON.decode(EvaluationSuite.self, from: data), nil)
        } catch {
            let preservation = preserveUnreadableFile(at: url, prefix: "suite-unreadable")
            let suffix = preservation.map { " It was preserved as \($0)." } ?? ""
            return (nil, "The saved suite could not be read.\(suffix)")
        }
    }

    static func loadSuiteLocalState(
        from url: URL,
        preserveUnreadable: Bool = true
    ) -> (state: EvaluationSuiteLocalState, notice: String?, persistenceBlocker: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let migrated = EvaluationWorkspacePersistence.hasCompletedLegacyStateMigration(
                in: url.deletingLastPathComponent()
            )
            return (
                EvaluationSuiteLocalState(),
                migrated ? "The saved suite state is missing after migration. Legacy approvals were not restored; review the suite state before release." : nil,
                nil
            )
        }
        do {
            let data = try Data(contentsOf: url)
            return (try CanonicalJSON.decode(EvaluationSuiteLocalState.self, from: data), nil, nil)
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
                blocker
            )
        }
    }

    static func loadJudgeConnections(
        from url: URL
    ) -> (connections: [EvaluationJudgeConnection], notice: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], nil) }
        do {
            let data = try Data(contentsOf: url)
            return (try CanonicalJSON.decode([EvaluationJudgeConnection].self, from: data), nil)
        } catch {
            let preservation = preserveUnreadableFile(
                at: url, prefix: "judge-connections-unreadable"
            )
            let suffix = preservation.map { " It was preserved as \($0)." } ?? ""
            return ([], "The saved judge connections could not be read.\(suffix)")
        }
    }

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
