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

    init(directory: URL) { self.directory = directory }

    static func key(for sample: EvaluationReviewSample) -> String {
        let identity = "\(sample.run.suiteID)/\(sample.run.id)/\(sample.sample.id)/\(sample.sourceDigest)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

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

    func update(_ draft: Draft, for key: String) {
        values[key] = draft
        tasks[key]?.cancel()
        tasks[key] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            self?.flush(key)
        }
    }

    func flush(_ key: String) {
        tasks[key]?.cancel(); tasks[key] = nil
        guard let value = values[key] else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try CanonicalJSON.data(for: value).write(to: url(for: key), options: .atomic)
            error = nil
        } catch { self.error = "Unfinished review is retained in this session but could not be saved: \(error.localizedDescription)" }
    }

    func clear(_ key: String) throws {
        tasks[key]?.cancel(); tasks[key] = nil
        let url = url(for: key)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        values[key] = nil
        error = nil
    }

    private func url(for key: String) -> URL { directory.appending(path: key + ".json") }
}
