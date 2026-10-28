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
    /// A consistent evidence snapshot with its external destination resolved before waiting for the store lock.
    /// - Parameter destination: A new absolute directory outside the active store for the job, dataset, reviews, and computed report.
    /// - Throws: An invalid-destination error, evidence validation errors, or file-system errors; temporary staging is cleaned up.
    public func exportJob(_ id: UUID, to destination: URL) throws {
        guard destination.isFileURL, destination.path.hasPrefix("/"), !FileManager.default.fileExists(atPath: destination.path) else {
            throw ProductionFailure.invalid("Choose a new absolute export directory.")
        }
        let resolvedDestination = Self.resolvedExportDestination(destination)
        guard !resolvedDestination.pathComponents.starts(with: Self.resolvedExportDestination(root).pathComponents) else {
            throw ProductionFailure.invalid("Choose an export directory outside the active store.")
        }
        try transaction {
            // Resolve the frozen path again in case one of its own parents changed while waiting for the lock.
            let destination = Self.resolvedExportDestination(resolvedDestination)
            guard !destination.pathComponents.starts(with: Self.resolvedExportDestination(root).pathComponents) else {
                throw ProductionFailure.invalid("Choose an export directory outside the active store.")
            }
            try writeExportSnapshot(id, to: destination)
        }
    }
    /// Publishes one managed evidence bundle beneath the canonical store's nonsymlink MCPExports directory.
    /// - Parameters:
    ///   - jobID: Frozen job whose dataset, results, reviews, and report are exported.
    ///   - exportID: UUID selecting a new directory; existing entries are never overwritten.
    /// - Returns: The canonical MCPExports/exportID directory, for trusted local callers only.
    /// - Throws: Invalid or symlinked managed paths, the 100-export retention limit, or snapshot/storage errors.
    public func exportManagedJob(jobID: UUID, exportID: UUID) throws -> URL {
        try transaction {
            let folder = Self.resolvedExportDestination(root).appendingPathComponent("MCPExports", isDirectory: true)
            let manager = FileManager.default
            if manager.fileExists(atPath: folder.path) || (try? manager.destinationOfSymbolicLink(atPath: folder.path)) != nil {
                let attributes = try manager.attributesOfItem(atPath: folder.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw ProductionFailure.invalid("Managed exports require a directory without symlinks.")
                }
            } else {
                try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            let destination = folder.appendingPathComponent(exportID.uuidString, isDirectory: true)
            guard !manager.fileExists(atPath: destination.path),
                  (try? manager.destinationOfSymbolicLink(atPath: destination.path)) == nil else {
                throw ProductionFailure.invalid("Managed export ID already exists.")
            }
            guard try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).count < 100 else {
                throw ProductionFailure.invalid("Export retention limit reached; preserve exports before operator cleanup.")
            }
            try writeExportSnapshot(jobID, to: destination)
            return destination
        }
    }
    /// Stages and publishes a consistent snapshot to a previously validated destination while the caller holds the store transaction.
    private func writeExportSnapshot(_ id: UUID, to destination: URL) throws {
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
    /// Resolves existing symlink components before interpreting later components, including a missing export leaf or parent.
    private static func resolvedExportDestination(_ url: URL) -> URL {
        var resolved = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            if component == "." { continue }
            if component == ".." { resolved.deleteLastPathComponent() }
            else { resolved.appendPathComponent(component) }
            resolved = resolved.resolvingSymlinksInPath()
        }
        return resolved
    }
}
