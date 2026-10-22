import Darwin
import Foundation

/// Each command gets a new session and process group at spawn, before any user
/// code runs. Only that positively owned group is signalled, never a PID search.
@MainActor
final class MacIntentOwnedCommand {
    private struct Child {
        let pid: pid_t
        var status: Int32?
        var anchorRetired = false
        var ownershipLost = false
    }
    enum Presence { case absent, present, unknown }
    enum ChildObservation { case running, exited(Int32), unowned }
    private var child: Child?
    private var cancelled = false
    private var executing = false
    private let cleanupGrace: Duration
    private let observeChild: (pid_t) -> ChildObservation
    private let probeGroup: (pid_t) -> Presence
    private let signalGroup: (pid_t, Int32) -> Int32
    var hasUnresolvedResources: Bool { child != nil }

    init(cleanupGrace: Duration = .seconds(1), observeChild: ((pid_t) -> ChildObservation)? = nil,
         probeGroup: ((pid_t) -> Presence)? = nil, signalGroup: ((pid_t, Int32) -> Int32)? = nil) {
        self.cleanupGrace = cleanupGrace
        self.observeChild = observeChild ?? Self.observe
        self.probeGroup = probeGroup ?? Self.presence
        self.signalGroup = signalGroup ?? { kill(-$0, $1) }
    }

    func cancel() { cancelled = true }

    /// waitid(WNOWAIT) preserves the child PID as a lifetime anchor. Once it
    /// is reaped, this record can only observe absence, never signal again.
    func confirmReleased() -> Bool {
        guard let child else { return true }
        if !child.anchorRetired {
            guard refreshOwnership(), self.child?.status != nil,
                  probeGroup(child.pid) != .present else { return false }
            // Darwin reports EPERM for a zombie-only group. Reap only after
            // its leader exited, then require ESRCH. An ambiguous/reused group
            // after this point remains unresolved and is never signalled.
            var status: Int32 = 0
            guard waitpid(child.pid, &status, WNOHANG) == child.pid else {
                self.child?.ownershipLost = true
                return false
            }
            self.child?.anchorRetired = true
        }
        guard probeGroup(child.pid) == .absent else { return false }
        self.child = nil
        return true
    }

    func execute(executable: URL, arguments: [String], directory: URL,
                 environment: [String: String], log: FileHandle, timeout: Double,
                 standardOutput: FileHandle? = nil) async throws -> Int32 {
        guard !executing, confirmReleased() else {
            throw MacIntentTestingError("An earlier command has unresolved processes. Wait for them to stop before running another test.")
        }
        try Task.checkCancellation()
        executing = true; cancelled = false
        defer { executing = false }
        child = .init(pid: try spawn(executable: executable, arguments: arguments, directory: directory,
            environment: environment, output: standardOutput ?? log, error: log))
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        var timedOut = false
        return try await withTaskCancellationHandler {
            while child?.status == nil {
                guard refreshOwnership() else {
                    throw MacIntentTestingError("Command ownership could not be verified. No process-group signal was sent; another test cannot start while this ownership is unresolved.")
                }
                if child?.status != nil { break }
                timedOut = ContinuousClock.now >= deadline
                if timedOut || cancelled || Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            let status = child?.status
            let leftovers = child.map { probeGroup($0.pid) == .present } ?? false
            let interrupted = timedOut || cancelled || Task.isCancelled
            if interrupted || leftovers {
                guard await stopAndDrain() else {
                    throw MacIntentTestingError("Command termination could not be verified. Its process ownership is retained; another test cannot start until those processes stop.")
                }
            } else if !confirmReleased() {
                guard await settleRetiredGroup(until: ContinuousClock.now.advanced(by: cleanupGrace)) else {
                    throw MacIntentTestingError("Command termination could not be verified after retiring its child PID. The remaining group will not be signalled.")
                }
            }
            if cancelled || Task.isCancelled { throw CancellationError() }
            if timedOut { throw MacIntentTestingError("\(executable.lastPathComponent) exceeded its \(timeout)-second timeout and was stopped.") }
            if leftovers { throw MacIntentTestingError("The command exited while its child work was still running. That work was stopped; this command did not complete cleanly.") }
            guard let status else { throw MacIntentTestingError("The command's exit status could not be verified.") }
            return status
        } onCancel: { Task { @MainActor in self.cancel() } }
    }

    private func stopAndDrain() async -> Bool {
        guard let pid = child?.pid else { return true }
        for signal in [SIGINT, SIGTERM, SIGKILL] {
            if confirmReleased() { return true }
            if child?.anchorRetired == true {
                return await settleRetiredGroup(until: ContinuousClock.now.advanced(by: cleanupGrace))
            }
            guard child?.anchorRetired == false, refreshOwnership(), probeGroup(pid) == .present else { return false }
            // No waitpid/reap may occur between this positive child ownership
            // observation and the signal: the reserved PID prevents PGID reuse.
            guard signalGroup(pid, signal) == 0 else {
                // The final descendant may exit between the probe and signal.
                // ESRCH is only a hint: release still requires the owned child
                // to be reaped and the group to be positively absent.
                guard errno == ESRCH else { return false }
                if confirmReleased() { return true }
                return await settleRetiredGroup(until: ContinuousClock.now.advanced(by: cleanupGrace))
            }
            let deadline = ContinuousClock.now.advanced(by: cleanupGrace)
            repeat {
                if confirmReleased() { return true }
                if child?.anchorRetired == true { return await settleRetiredGroup(until: deadline) }
                if child?.ownershipLost == true { return false }
                // Cancellation cannot skip ownership cleanup or turn this into a busy loop.
                await Task.detached { try? await Task.sleep(for: .milliseconds(25)) }.value
            } while ContinuousClock.now < deadline
        }
        return confirmReleased()
    }

    private func settleRetiredGroup(until deadline: ContinuousClock.Instant) async -> Bool {
        guard child?.anchorRetired == true else { return false }
        // Descendant zombies may briefly keep a group visible after leader
        // reap. With the PID reservation gone, only observe: even a present
        // group supplies no authority to signal this possibly reused number.
        while ContinuousClock.now < deadline {
            if confirmReleased() { return true }
            await Task.detached { try? await Task.sleep(for: .milliseconds(25)) }.value
        }
        return confirmReleased()
    }

    private func refreshOwnership() -> Bool {
        guard let child, !child.anchorRetired, !child.ownershipLost else { return false }
        switch observeChild(child.pid) {
        case .running: return true
        case .exited(let status): self.child?.status = status; return true
        case .unowned: self.child?.ownershipLost = true; return false
        }
    }

    private static func observe(_ pid: pid_t) -> ChildObservation {
        var info = siginfo_t()
        var result: Int32 = -1
        for _ in 0..<3 {
            result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT | WNOHANG)
            if result == 0 || errno != EINTR { break }
        }
        guard result == 0 else { return .unowned }
        if info.si_pid == 0 { return .running }
        guard info.si_pid == pid else { return .unowned }
        switch info.si_code {
        case CLD_EXITED: return .exited(info.si_status)
        case CLD_KILLED, CLD_DUMPED: return .exited(128 + info.si_status)
        default: return .unowned
        }
    }

    private static func presence(_ group: pid_t) -> Presence {
        if kill(-group, 0) == 0 { return .present }
        return errno == ESRCH ? .absent : .unknown
    }

    private func spawn(executable: URL, arguments: [String], directory: URL,
                       environment: [String: String], output: FileHandle, error: FileHandle) throws -> pid_t {
        guard executable.isFileURL, directory.isFileURL,
              !([executable.path, directory.path] + arguments).contains(where: { $0.contains("\0") }),
              !environment.contains(where: { $0.key.contains("=") || $0.key.contains("\0") || $0.value.contains("\0") }) else {
            throw MacIntentTestingError("Invalid command arguments or environment.")
        }
        var attributes: posix_spawnattr_t?, actions: posix_spawn_file_actions_t?
        try checked(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try checked(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        var signals = sigset_t(); sigemptyset(&signals)
        try checked(posix_spawnattr_setsigmask(&attributes, &signals))
        for signal in [SIGINT, SIGTERM, SIGHUP, SIGPIPE] { sigaddset(&signals, signal) }
        try checked(posix_spawnattr_setsigdefault(&attributes, &signals))
        try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))
        try checked(posix_spawn_file_actions_addchdir(&actions, directory.path))
        try checked(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try checked(posix_spawn_file_actions_adddup2(&actions, output.fileDescriptor, STDOUT_FILENO))
        try checked(posix_spawn_file_actions_adddup2(&actions, error.fileDescriptor, STDERR_FILENO))
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.keys.sorted().map { strdup($0 + "=" + environment[$0]!) } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&pid, executable.path, &actions, &attributes,
                    UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!))
            }
        }
        try checked(result)
        return pid
    }

    private func checked(_ status: Int32) throws {
        guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(status)) }
    }
}
