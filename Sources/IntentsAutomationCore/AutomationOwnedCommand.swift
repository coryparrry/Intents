#if os(macOS) || os(Linux)
import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Native-only process primitive. It is never exposed through the worker broker.
public actor AutomationOwnedCommand {
    private final class LogOverflow: Sendable { let value = Mutex(false) }
    public struct Result: Sendable {
        public var exitStatus: Int32
        public var stdout: Data
        public var stderr: Data
        public var logsTruncated: Bool
        public var ownedIdentity: AutomationProcessIdentity? = nil
        public var directChildReaped = false
        public var pipesDrained = false
        public var callbacksDrained = false
    }
    private var process: Process?
    private var identity: AutomationProcessIdentity?
    private var lastCapturedIdentity: AutomationProcessIdentity?
    private var output = Data(), diagnostics = Data()
    private var truncated = false
    private var launchRevoked = false
    private var lastLogOverflow: LogOverflow?
    private let presenceReader: @Sendable (AutomationProcessIdentity) -> AutomationProcessIdentity.Presence
    private let identityReader: @Sendable (Int32) -> AutomationProcessIdentity?
    private var launched = false
    private var callback: AutomationBoundedTask<Bool>?
    private var runInProgress = false
    private var stopOperations = 0
    public init() {
        presenceReader = { $0.presence() }
        identityReader = { AutomationProcessIdentity.inspect(pid: $0) }
    }
    init(presenceReader: @escaping @Sendable (AutomationProcessIdentity) -> AutomationProcessIdentity.Presence,
         identityReader: @escaping @Sendable (Int32) -> AutomationProcessIdentity? = { AutomationProcessIdentity.inspect(pid: $0) }) {
        self.presenceReader = presenceReader; self.identityReader = identityReader
    }
    /// Available after failure/cancellation as well as success; bounded by the same pipe limits.
    public func retainedLogs() -> Result {
        .init(exitStatus: launched && process?.isRunning == false ? process!.terminationStatus : -1, stdout: output, stderr: diagnostics,
              logsTruncated: truncated || (lastLogOverflow?.value.withLock { $0 } ?? false), ownedIdentity: lastCapturedIdentity)
    }
    public func run(executable: URL, arguments: [String], directory: URL, environment: [String: String],
                    timeout: Duration,
                    willStart: @escaping @Sendable () async throws -> Void = {}, didStart: @escaping @Sendable (AutomationProcessIdentity) async throws -> Void = { _ in }) async throws -> Result {
        try await run(executable: executable, arguments: arguments, directory: directory, environment: environment,
            timeout: timeout, absoluteDeadline: nil, willStart: willStart, didStart: didStart)
    }
    func run(executable: URL, arguments: [String], directory: URL, environment: [String: String],
             timeout: Duration, absoluteDeadline: ContinuousClock.Instant?,
             willStart: @escaping @Sendable () async throws -> Void = {}, didStart: @escaping @Sendable (AutomationProcessIdentity) async throws -> Void = { _ in }) async throws -> Result {
        try Task.checkCancellation()
        guard process == nil, !runInProgress, stopOperations == 0, callback == nil,
              executable.isFileURL, executable.path == (try AutomationPath.canonical(executable)).path,
              arguments.count <= 128, arguments.allSatisfy({ $0.utf8.count <= 65_536 && !$0.contains("\0") }),
              environment.count <= 32, environment.allSatisfy({ !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") && $0.value.utf8.count <= 65_536 }) else {
            throw AutomationContractError.invalidIdentity
        }
        let relativeDeadline = ContinuousClock.now.advanced(by: timeout)
        let deadline = min(relativeDeadline, absoluteDeadline ?? relativeDeadline)
        guard deadline > ContinuousClock.now else { throw AutomationRPCError.timedOut }
        output = Data(); diagnostics = Data(); truncated = false; lastCapturedIdentity = nil
        let child = Process(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = executable; child.arguments = arguments; child.environment = environment
        child.currentDirectoryURL = try AutomationPath.canonical(directory)
        child.standardInput = FileHandle.nullDevice; child.standardOutput = stdout; child.standardError = stderr
        let overflow = LogOverflow()
        lastLogOverflow = overflow
        let out = Self.stream(stdout.fileHandleForReading, overflow: overflow), err = Self.stream(stderr.fileHandleForReading, overflow: overflow)
        process = child; launchRevoked = false; launched = false
        runInProgress = true
        defer { runInProgress = false }
        do {
            let pending = AutomationBoundedTask<Bool>(); callback = pending
            _ = try await pending.run(until: deadline) { try await willStart(); return true }
            callback = nil
            try Task.checkCancellation()
            guard !launchRevoked else { throw CancellationError() }
            guard ContinuousClock.now < deadline else { throw AutomationRPCError.timedOut }
            try child.run()
            launched = true
        } catch {
            let stopped = await Task.detached { await self.stopOwned() }.value
            stdout.fileHandleForReading.readabilityHandler = nil; stderr.fileHandleForReading.readabilityHandler = nil
            try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
            if stopped { process = nil; identity = nil }
            if !stopped { throw AutomationContractError.terminationUnverified }
            throw error
        }
        try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
        let outReader = Task { for await data in out { append(data, diagnostic: false) } }
        let errReader = Task { for await data in err { append(data, diagnostic: true) } }
        let waiter = AutomationBoundedTask<Bool>()
        do {
            if let started = identityReader(child.processIdentifier) {
                identity = started
                lastCapturedIdentity = started
                let pending = AutomationBoundedTask<Bool>(); callback = pending
                _ = try await pending.run(until: deadline) { try await didStart(started); return true }
                callback = nil
            } else {
                // Exit can precede Foundation's notification and kernel PID removal.
                // Wait read-only; recapturing this PID could adopt a recycled process.
                while !Self.permitsUncapturedExit(pid: child.processIdentifier, isRunning: child.isRunning) {
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline else { throw AutomationRPCError.timedOut }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            let exited = try await waiter.run(until: deadline) { await self.waitForExit(child) }
            _ = try await AutomationBoundedTask<Bool>().run(until: deadline) { await outReader.value; await errReader.value; return true }
            try Task.checkCancellation()
            guard exited, terminated(child) else { throw AutomationContractError.terminationUnverified }
            let result = Result(exitStatus: child.terminationStatus, stdout: output, stderr: diagnostics,
                                logsTruncated: truncated || overflow.value.withLock { $0 }, ownedIdentity: identity,
                                directChildReaped: true, pipesDrained: true,
                                callbacksDrained: true)
            process = nil; identity = nil; output = Data(); diagnostics = Data(); truncated = false
            return result
        } catch {
            let stopped = await Task.detached { await self.stopOwned() }.value
            outReader.cancel(); errReader.cancel()
            await outReader.value; await errReader.value
            // Keep an unproved running child attached; a subsequent run cannot overwrite its ownership.
            if stopped { process = nil; identity = nil }
            if !stopped { throw AutomationContractError.terminationUnverified }
            throw error
        }
    }
    public func stopOwned() async -> Bool {
        stopOperations += 1
        defer { stopOperations -= 1 }
        launchRevoked = true
        let child = process, pending = callback
        await pending?.requestCancellation()
        let processStopped: Bool
        if let child { processStopped = await stopProcess(child) } else { processStopped = true }
        let callbacksDrained: Bool
        if let pending {
            callbacksDrained = await pending.cancelAndDrain(until: .now.advanced(by: .seconds(2)))
            if callbacksDrained { callback = nil }
        } else { callbacksDrained = true }
        let stopped = processStopped && callbacksDrained
        if stopped && !runInProgress { process = nil; identity = nil }
        return stopped
    }
    private func stopProcess(_ child: Process) async -> Bool {
        if child.isRunning {
            guard let identity, presenceReader(identity) == .matching else { return false }
            child.terminate()
        }
        let grace = ContinuousClock.now.advanced(by: .seconds(2))
        while child.isRunning && ContinuousClock.now < grace { try? await Task.sleep(for: .milliseconds(50)) }
        if child.isRunning {
            guard let identity, presenceReader(identity) == .matching else { return false }
            _ = kill(child.processIdentifier, SIGKILL)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !terminated(child) && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return terminated(child)
    }
    // This only permits waiting for a delayed exit notification; it never grants signal ownership.
    nonisolated static func permitsUncapturedExit(pid: Int32, isRunning: Bool) -> Bool {
        guard pid > 0 else { return false }
        return !isRunning || (kill(pid, 0) == -1 && errno == ESRCH)
    }
    private func terminated(_ child: Process) -> Bool {
        guard !child.isRunning else { return false }
        if !launched { return launchRevoked }
        if let identity { return [.absent, .replaced].contains(presenceReader(identity)) }
        // A child can exit before its start identity is captured. Require kernel absence.
        return child.processIdentifier > 0 && kill(child.processIdentifier, 0) == -1 && errno == ESRCH
    }
    private func waitForExit(_ child: Process) async -> Bool {
        while !terminated(child) {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }
    private func append(_ bytes: Data, diagnostic: Bool) {
        let count = diagnostic ? diagnostics.count : output.count
        let remaining = max(0, 1_048_576 - count)
        if diagnostic { diagnostics.append(bytes.prefix(remaining)) } else { output.append(bytes.prefix(remaining)) }
        if bytes.count > remaining { truncated = true }
    }
    private static func stream(_ handle: FileHandle, overflow: LogOverflow) -> AsyncStream<Data> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            handle.readabilityHandler = { file in
                let bytes = file.availableData
                if bytes.isEmpty { file.readabilityHandler = nil; continuation.finish() }
                else if case .dropped = continuation.yield(bytes) { overflow.value.withLock { $0 = true } }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
    }
}
#endif
