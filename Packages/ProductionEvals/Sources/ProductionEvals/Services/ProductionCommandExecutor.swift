#if os(macOS)
import Foundation
import Darwin

public struct ProductionCommandContext: Codable, Sendable {
    public var kind = "command"
    public var executableDigest: String
    public var settings: Data?
    public init(executableDigest: String, settings: Data? = nil) { self.executableDigest = executableDigest; self.settings = settings }
}

public struct ProductionCommandExecutor: Sendable {
    public let executable: URL
    public let executableDigest: String
    public init(executable: URL) throws {
        guard executable.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable.path),
              (try executable.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw ProductionFailure.invalid("Worker executable must be an explicitly supplied absolute executable file.")
        }
        self.executable = executable.resolvingSymlinksInPath()
        self.executableDigest = try ProductionCodec.fileDigest(self.executable)
    }
    public func execute(_ request: ProductionRequest) async throws -> ProductionResponse {
        let context = try ProductionCodec.decode(ProductionCommandContext.self, request.configuration.executionContext)
        guard context.kind == "command", context.executableDigest == executableDigest,
              try ProductionCodec.fileDigest(executable) == executableDigest else {
            throw ProductionFailure.integrity("Worker executable differs from the frozen job contract.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("intents-worker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.json"), output = directory.appendingPathComponent("output.json")
        try ProductionCodec.encode(request).write(to: input)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let inputHandle = try FileHandle(forReadingFrom: input), outputHandle = try FileHandle(forWritingTo: output)
        defer { try? inputHandle.close(); try? outputHandle.close() }
        let process = ProductionChildProcess()
        process.process.executableURL = executable; process.process.arguments = []
        process.process.standardInput = inputHandle; process.process.standardOutput = outputHandle
        // Worker diagnostics can contain secrets; they are not copied into qualification reports.
        process.process.standardError = FileHandle.nullDevice
        let monitor = Task {
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(100))
                if ((try? ProductionCodec.fileSize(output)) ?? 0) > 524_288 { process.cancel(); return }
            }
        }
        defer { monitor.cancel() }
        let status = try await withTaskCancellationHandler {
            try await process.run()
        } onCancel: { process.cancel() }
        guard status == 0 else { throw ProductionFailure.unavailable("Worker exited with status \(status); no result was accepted.") }
        let size = try ProductionCodec.fileSize(output)
        guard size > 0, size <= 524_288 else { throw ProductionFailure.invalid("Worker output is empty or exceeds 512 KB.") }
        return try ProductionCodec.decode(ProductionResponse.self, Data(contentsOf: output))
    }
}

private final class ProductionChildProcess: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    func run() async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    self.lock.lock()
                    if self.cancelled { self.lock.unlock(); throw CancellationError() }
                    do { try self.process.run() } catch { self.lock.unlock(); throw error }
                    self.lock.unlock()
                    self.process.waitUntilExit()
                    continuation.resume(returning: self.process.terminationStatus)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func cancel() {
        lock.lock(); cancelled = true
        if process.isRunning { process.terminate() }; lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            self.lock.lock(); defer { self.lock.unlock() }
            if self.process.isRunning { _ = kill(self.process.processIdentifier, SIGKILL) }
        }
    }
}
#endif
