import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Small private store with cross-process exclusion and fsync before returning authority.
struct AutomationDurableFile: Sendable {
    let url: URL
    let maximumBytes: Int
    init(url: URL, maximumBytes: Int, existingParentOnly: Bool = false) throws {
        guard url.isFileURL, maximumBytes > 0 else { throw AutomationContractError.invalidIdentity }
        let parent = url.deletingLastPathComponent()
        if !existingParentOnly {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        self.url = try AutomationPath.canonical(parent).appendingPathComponent(url.lastPathComponent)
        self.maximumBytes = maximumBytes
        try validateParent()
    }
    func withLock<T>(_ body: () throws -> T) throws -> T {
        try validateParent()
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw AutomationContractError.targetBusy }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0 else { throw AutomationContractError.invalidIdentity }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw AutomationContractError.targetBusy }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    func read() throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw AutomationContractError.invalidIdentity
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o022 == 0,
              info.st_size >= 0, info.st_size <= maximumBytes else {
            close(fd); throw AutomationContractError.invalidIdentity
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw AutomationContractError.invalidIdentity }
        return data
    }
    func write(_ data: Data, stagingName: String? = nil) throws {
        guard data.count <= maximumBytes else { throw AutomationContractError.invalidIdentity }
        let name = stagingName ?? ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        guard !name.isEmpty, !name.contains("/"), !name.contains("\u{0}"), name != ".", name != ".." else { throw AutomationContractError.invalidIdentity }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(name)
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw AutomationContractError.invalidIdentity }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        guard rename(temporary.path, url.path) == 0 else { throw AutomationContractError.invalidIdentity }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw AutomationContractError.invalidIdentity }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw AutomationContractError.invalidIdentity }
    }
    private func validateParent() throws {
        var parent = url.deletingLastPathComponent()
        while true {
            var info = stat()
            guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == 0 || info.st_uid == getuid() else { throw AutomationContractError.invalidIdentity }
            if info.st_mode & 0o022 != 0 {
                // Root-owned sticky system temporary directories protect each owned child.
                guard parent != url.deletingLastPathComponent(), info.st_uid == 0,
                      info.st_mode & S_ISVTX != 0 else { throw AutomationContractError.invalidIdentity }
            }
            if parent.path == "/" { break }
            parent.deleteLastPathComponent()
        }
    }
}
