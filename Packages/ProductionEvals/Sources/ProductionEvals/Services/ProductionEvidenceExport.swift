import Foundation

public struct ProductionCapturedContext: Codable, Sendable {
    public let kind: String
    /// Selects the versioned context marker for reviewing captured outputs without inference.
    public init() { kind = "captured-output-review-v1" }
}

extension ProductionStorage {
    /// Captured outputs are retained verbatim for review; inference is never re-run.
    /// - Throws: An invalid-input error if any example lacks its original output, or dataset/job/storage errors.
    public func createCapturedJob(name: String, datasetRevision: String, id: UUID = UUID()) throws -> ProductionJob {
        let context = try ProductionCodec.encode(ProductionCapturedContext())
        let config = ProductionJobConfiguration(scoringRevision: ProductionCodec.digest(Data("human-review-v1".utf8)),
            executionRevision: ProductionCodec.digest(context), executionContext: context)
        let reader = try ProductionDatasetReader(storage: self, revision: datasetRevision)
        for index in 0..<reader.dataset.count {
            guard try reader.example(at: index).capturedOutput != nil else { throw ProductionFailure.invalid("Every captured example needs its original output.") }
        }
        return try createJob(name: name, datasetRevision: datasetRevision, configuration: config, id: id)
    }
    /// Returns the original captured output and feedback as unscored evidence with unavailable latency and zero new execution cost.
    /// - Throws: An invalid-context error when the frozen marker or captured output is missing.
    public static func capturedResponse(_ request: ProductionRequest) throws -> ProductionResponse {
        let context = try ProductionCodec.decode(ProductionCapturedContext.self, request.configuration.executionContext)
        guard context.kind == "captured-output-review-v1", let output = request.example.capturedOutput else {
            throw ProductionFailure.invalid("This job does not contain captured output evidence.")
        }
        return .init(requestID: request.requestID, outcome: .unscored, output: output,
                     explanation: request.example.feedback, latencyAvailable: false, cost: 0)
    }
    /// A consistent evidence snapshot. Nothing is removed from the active store.
    /// - Parameter destination: A new absolute directory for the job, dataset, reviews, and computed report.
    /// - Throws: An invalid-destination error, evidence validation errors, or file-system errors; temporary staging is cleaned up.
    public func exportJob(_ id: UUID, to destination: URL) throws {
        guard destination.isFileURL, destination.path.hasPrefix("/"), !FileManager.default.fileExists(atPath: destination.path) else {
            throw ProductionFailure.invalid("Choose a new absolute export directory.")
        }
        try transaction {
            let report = try makeReport(jobID: id, includeBaseline: true)
            let job = try loadJob(id)
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".eval-export-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.copyItem(at: jobDirectory(id), to: staging.appendingPathComponent("Job"))
            try FileManager.default.copyItem(at: datasetDirectory(job.datasetRevision), to: staging.appendingPathComponent("Dataset"))
            let reviews = staging.appendingPathComponent("Reviews")
            try FileManager.default.createDirectory(at: reviews, withIntermediateDirectories: true)
            for url in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Reviews"), includingPropertiesForKeys: nil)
                where url.lastPathComponent.hasPrefix(id.uuidString + "-") {
                try FileManager.default.copyItem(at: url, to: reviews.appendingPathComponent(url.lastPathComponent))
            }
            try ProductionCodec.write(report, to: staging.appendingPathComponent("report.json"))
            try FileManager.default.moveItem(at: staging, to: destination)
        }
    }
}
