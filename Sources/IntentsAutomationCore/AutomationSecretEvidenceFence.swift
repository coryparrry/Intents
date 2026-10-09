import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A shared read lock is retained by the actual provider task, even if its caller
/// times out. Secret admission uses the matching nonblocking exclusive lock.
final class AutomationSecretEvidencePermit: @unchecked Sendable {
    private let mutex = NSLock()
    private var descriptor: Int32
    init(file: AutomationDurableFile) throws {
        let fd = open(file.url.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw AutomationContractError.targetBusy }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              flock(fd, LOCK_SH | LOCK_NB) == 0 else {
            close(fd); throw AutomationContractError.targetBusy
        }
        do {
            guard try file.read() == nil else { throw AutomationContractError.missingEvidence("Secret-tainted evidence is withheld") }
        } catch { flock(fd, LOCK_UN); close(fd); throw error }
        descriptor = fd
    }
    func release() {
        mutex.withLock {
            if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 }
        }
    }
    deinit { release() }
}

struct AutomationSecretEvidenceFence: Sendable {
    let root: URL
    init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.root = try AutomationPath.canonical(root)
        // Persist this owned directory's entry before a later marker can permit
        // secret input. The marker itself uses durable file+directory writes.
        let parent = open(self.root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw AutomationContractError.invalidIdentity }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw AutomationContractError.invalidIdentity }
    }
    private func file(_ scope: AutomationScope) throws -> AutomationDurableFile {
        try scope.validate()
        return try .init(url: root.appendingPathComponent("secret-evidence-" + AutomationArtifactRegistry.digest(Data(scope.runId.utf8)) + ".json"), maximumBytes: 4096)
    }
    func restrict(_ scope: AutomationScope) throws {
        let store = try file(scope), bytes = try JSONEncoder().encode(["runID": scope.runId])
        try store.withLock {
            try store.write(bytes)
            guard try store.read() == bytes else { throw AutomationContractError.conflictingOperation }
        }
    }
    func permits(_ scope: AutomationScope) -> Bool {
        do { return try file(scope).read() == nil } catch { return false }
    }
    func reserve(_ scope: AutomationScope) throws -> AutomationSecretEvidencePermit {
        try AutomationSecretEvidencePermit(file: file(scope))
    }
}
