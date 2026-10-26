import CryptoKit
import Foundation
import Observation

/// Unconfirmed edits are local drafts, kept separately from labels and exported suites.
@MainActor @Observable
final class EvaluationReviewDraftStore {
    struct Draft: Codable, Equatable {
        var reviewID: UUID
        var verdict: EvaluationReviewVerdict
        var note: String
        var tags: String
    }
    private let directory: URL
    private var values: [String: Draft] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    private(set) var error: String?

    /// Creates a main-actor review draft cache backed by the supplied directory, loading values lazily.
    init(directory: URL) { self.directory = directory }

    /// Hashes suite, run, sample, and source-digest identity so drafts remain bound to their reviewed evidence.
    static func key(for sample: EvaluationReviewSample) -> String {
        let identity = "\(sample.run.suiteID)/\(sample.run.id)/\(sample.sample.id)/\(sample.sourceDigest)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns a cached draft or lazily restores its JSON file, publishing a restore error and nil on decode/read failure.
    func draft(for key: String) -> Draft? {
        if let value = values[key] { return value }
        let url = url(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let value = try CanonicalJSON.decode(Draft.self, from: Data(contentsOf: url))
            values[key] = value
            return value
        } catch {
            self.error = "Could not restore the unfinished review: \(error.localizedDescription)"
            return nil
        }
    }

    /// Updates the session cache and replaces this key's pending write with a 400 ms debounce task.
    func update(_ draft: Draft, for key: String) {
        values[key] = draft
        tasks[key]?.cancel()
        tasks[key] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            self?.flush(key)
        }
    }

    /// Cancels the key's timer and atomically writes its cached draft, retaining the in-memory value and error on failure.
    func flush(_ key: String) {
        tasks[key]?.cancel(); tasks[key] = nil
        guard let value = values[key] else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try CanonicalJSON.data(for: value).write(to: url(for: key), options: .atomic)
            error = nil
        } catch { self.error = "Unfinished review is retained in this session but could not be saved: \(error.localizedDescription)" }
    }

    /// Cancels the pending write, removes the saved draft, then clears its cache and error.
    /// A file-removal failure throws before the cached draft is discarded.
    func clear(_ key: String) throws {
        tasks[key]?.cancel(); tasks[key] = nil
        let url = url(for: key)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        values[key] = nil
        error = nil
    }

    /// Flushes every cached draft, including earlier failed writes, and retains the first encountered error.
    func flushPendingDrafts() {
        var firstError: String?
        // Include drafts whose earlier write failed after its timer was removed.
        for key in Array(values.keys).sorted() {
            flush(key)
            firstError = firstError ?? error
        }
        error = firstError
    }

    /// Returns the JSON file path for a draft key in this store's directory.
    private func url(for key: String) -> URL { directory.appending(path: key + ".json") }
}
