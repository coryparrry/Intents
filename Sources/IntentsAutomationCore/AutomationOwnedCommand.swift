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
        public var startupAcknowledged = false
        public var callbacksDrained = false
    }
    private var process: Process?
    private var identity: AutomationProcessIdentity?
    private var lastCapturedIdentity: AutomationProcessIdentity?
    private var lastStartupAcknowledged = false
    private var output = Data(), diagnostics = Data()
    private var truncated = false
    private var launchRevoked = false
    private var lastLogOverflow: LogOverflow?
    private let presenceReader: @Sendable (AutomationProcessIdentity) -> AutomationProcessIdentity.Presence
    private var launched = false
    private var callback: AutomationBoundedTask<Bool>?
    private var runInProgress = false
    private var stopOperations = 0
    public init() { presenceReader = { $0.presence() } }
    init(presenceReader: @escaping @Sendable (AutomationProcessIdentity) -> AutomationProcessIdentity.Presence) { self.presenceReader = presenceReader }
    /// Available after failure/cancellation as well as success; bounded by the same pipe limits.
    public func retainedLogs() -> Result {
        .init(exitStatus: launched && process?.isRunning == false ? process!.terminationStatus : -1, stdout: output, stderr: diagnostics,
              logsTruncated: truncated || (lastLogOverflow?.value.withLock { $0 } ?? false), ownedIdentity: lastCapturedIdentity,
              startupAcknowledged: lastStartupAcknowledged)
    }
    public func run(executable: URL, arguments: [String], directory: URL, environment: [String: String],
                    timeout: Duration, ownershipGateNonce: String? = nil, privateInputFrame: Data? = nil,
                    willStart: @escaping @Sendable () async throws -> Void = {}, didStart: @escaping @Sendable (AutomationProcessIdentity) async throws -> Void = { _ in },
                    willAcknowledge: @escaping @Sendable () async throws -> Void = {}) async throws -> Result {
        try Task.checkCancellation()
        if let privateInputFrame {
            guard ownershipGateNonce != nil else { throw AutomationContractError.invalidIdentity }
            try AutomationCommandGateInput.validatePrivateFrame(privateInputFrame)
        }
        if let nonce = ownershipGateNonce {
            try AutomationMacHelperHandshake.validateNonce(nonce)
            guard environment.count < 32, environment["INTENTS_MAC_HELPER_OWNERSHIP_NONCE"] == nil else { throw AutomationContractError.invalidIdentity }
        }
        guard process == nil, !runInProgress, stopOperations == 0, callback == nil,
              executable.isFileURL, executable.path == (try AutomationPath.canonical(executable)).path,
              arguments.count <= 128, arguments.allSatisfy({ $0.utf8.count <= 65_536 && !$0.contains("\0") }),
              environment.count <= 32, environment.allSatisfy({ !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") && $0.value.utf8.count <= 65_536 }) else {
            throw AutomationContractError.invalidIdentity
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        guard deadline > ContinuousClock.now else { throw AutomationRPCError.timedOut }
        output = Data(); diagnostics = Data(); truncated = false; lastCapturedIdentity = nil; lastStartupAcknowledged = false
        let child = Process(), stdout = Pipe(), stderr = Pipe()
        let gateInput = try ownershipGateNonce.map { _ in try AutomationCommandGateInput() }
        child.executableURL = executable; child.arguments = arguments; child.environment = environment
        if let nonce = ownershipGateNonce { child.environment?["INTENTS_MAC_HELPER_OWNERSHIP_NONCE"] = nonce }
        child.currentDirectoryURL = try AutomationPath.canonical(directory)
        child.standardInput = gateInput?.childHandle ?? FileHandle.nullDevice; child.standardOutput = stdout; child.standardError = stderr
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
            try child.run()
            launched = true
            gateInput?.childStarted()
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
        var acknowledged = false
        do {
            if let started = AutomationProcessIdentity.inspect(pid: child.processIdentifier) {
                identity = started
                lastCapturedIdentity = started
                let pending = AutomationBoundedTask<Bool>(); callback = pending
                _ = try await pending.run(until: deadline) { try await didStart(started); return true }
                callback = nil
            } else {
                guard ownershipGateNonce == nil else { throw AutomationContractError.invalidIdentity }
                guard !child.isRunning else { throw AutomationContractError.invalidIdentity }
            }
            if let nonce = ownershipGateNonce, let identity, let gateInput {
                while output.firstIndex(of: 10) == nil {
                    try Task.checkCancellation()
                    guard !launchRevoked, child.isRunning, output.count <= 4096, !overflow.value.withLock({ $0 }),
                          ContinuousClock.now < deadline else { throw AutomationContractError.terminationUnverified }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let ready = output
                let ack = try AutomationMacHelperHandshake.acknowledgement(ready: ready, nonce: nonce, ownedChild: identity)
                let pending = AutomationBoundedTask<Bool>(); callback = pending
                _ = try await pending.run(until: deadline) { try await willAcknowledge(); return true }
                callback = nil
                try Task.checkCancellation()
                guard !launchRevoked, presenceReader(identity) == .matching, ContinuousClock.now < deadline else {
                    throw AutomationContractError.terminationUnverified
                }
                output.removeFirst(ready.count)
                try await gateInput.acknowledge(ack, keepOpen: privateInputFrame != nil, deadline: deadline,
                    isolation: self, beforeWrite: { try self.requireGateWrite(identity) })
                acknowledged = true; lastStartupAcknowledged = true
                if let privateInputFrame {
                    try await gateInput.writePrivateFrame(privateInputFrame, deadline: deadline,
                        isolation: self, beforeWrite: { try self.requireGateWrite(identity) })
                }
            }
            let exited = try await waiter.run(until: deadline) { await self.waitForExit(child) }
            _ = try await AutomationBoundedTask<Bool>().run(until: deadline) { await outReader.value; await errReader.value; return true }
            try Task.checkCancellation()
            guard exited, terminated(child) else { throw AutomationContractError.terminationUnverified }
            let result = Result(exitStatus: child.terminationStatus, stdout: output, stderr: diagnostics,
                                logsTruncated: truncated || overflow.value.withLock { $0 }, ownedIdentity: identity,
                                directChildReaped: true, pipesDrained: true, startupAcknowledged: acknowledged,
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
    private func requireGateWrite(_ expected: AutomationProcessIdentity) throws {
        guard !launchRevoked, identity == expected, presenceReader(expected) == .matching else {
            throw AutomationContractError.terminationUnverified
        }
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
