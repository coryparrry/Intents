import AppKit
import Foundation
import Darwin

/// The installed app's existing runner can serve frozen native-suite jobs without MCP or a visible window.
@MainActor enum ProductionNativeWorkerCommand {
    static var scratchDirectory: URL?
    static func prepareScratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-eval-worker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        scratchDirectory = directory
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--production-judge-connections") {
            guard arguments.indices.contains(index+1), arguments[index+1].hasPrefix("/") else { throw ProductionFailure.invalid("Judge connection configuration must be an explicit absolute file.") }
            let source = URL(fileURLWithPath: arguments[index+1])
            guard (try source.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 1_000_001 <= 1_000_000 else { throw ProductionFailure.invalid("Judge connection configuration exceeds 1 MB.") }
            try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent("judge-connections.json"))
        }
        return directory
    }
    static func finish(_ code: Int32) -> Never {
        if let scratchDirectory { try? FileManager.default.removeItem(at: scratchDirectory) }
        exit(code)
    }
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("--production-worker-store") }
    static func run(store: EvaluationStore) async {
        do {
            let arguments = ProcessInfo.processInfo.arguments
            func value(_ flag: String) throws -> String {
                guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index+1), !arguments[index+1].hasPrefix("--") else {
                    throw ProductionFailure.invalid("Missing \(flag)")
                }
                return arguments[index+1]
            }
            let path = try value("--production-worker-store")
            guard path.hasPrefix("/") else { throw ProductionFailure.invalid("Worker storage must be an explicit absolute directory.") }
            let identifier = try value("--production-worker-id")
            let selectedJob: UUID?
            if arguments.contains("--production-job") {
                guard let id = UUID(uuidString: try value("--production-job")) else { throw ProductionFailure.invalid("Invalid job ID.") }
                selectedJob = id
            } else { selectedJob = nil }
            let storage = try ProductionStorage(root: URL(fileURLWithPath: path))
            repeat {
                _ = try storage.tickSchedules()
                let jobs = try selectedJob.map { [try storage.loadJob($0)] } ?? Array(storage.jobs().reversed())
                for job in jobs {
                    guard let context = try? ProductionCodec.decode(NativeProductionContext.self, job.configuration.executionContext), context.kind == "native-suite-v1" else {
                        if selectedJob != nil { throw ProductionFailure.invalid("Use the CLI worker for this job's execution backend.") }
                        continue
                    }
                    let control = try storage.control(job)
                    if control.paused || control.cancelled { continue }
                    let completed = try (0..<storage.chunkCount(job)).reduce(0) { try $0 + storage.chunk(job, index: $1).records.count }
                    if completed == job.plannedCount { continue }
                    var owner: UUID?
                    do {
                        let admission = try store.beginProductionExecution(context, externalDisclosureApproved: arguments.contains("--approve-external-judge"))
                        owner = admission.0
                        let executor = try NativeProductionExecutor(context: context, executionRevision: job.configuration.executionRevision, judge: admission.1)
                        #if arch(arm64)
                        let hardware = "Apple silicon"
                        #else
                        let hardware = "Intel"
                        #endif
                        let worker = ProductionWorker(id: identifier, name: identifier, platform: "macOS", operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                            hardware: hardware, locale: Locale.current.identifier, model: context.reportedModel)
                        _ = try await ProductionBatchRunner(storage: storage).run(jobID: job.id, worker: worker) { try await executor.execute($0) }
                    } catch {
                        if let owner { store.endProductionExecution(owner) }
                        if selectedJob != nil { throw error }
                        FileHandle.standardError.write(Data(("\(job.id): \(error.localizedDescription)\n").utf8)); continue
                    }
                    if let owner { store.endProductionExecution(owner) }
                }
                if !arguments.contains("--production-poll") {
                    if let selectedJob {
                        let report = try storage.report(jobID: selectedJob)
                        FileHandle.standardOutput.write(try ProductionCodec.encode(report)); print(""); finish(Int32(report.exitCode))
                    }
                    finish(0)
                }
                try await Task.sleep(for: .seconds(2))
            } while !Task.isCancelled
            finish(0)
        } catch { FileHandle.standardError.write(Data(("Native eval worker: \(error.localizedDescription)\n").utf8)); finish(30) }
    }
}
