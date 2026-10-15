import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum AutomationReadOnlyFile {
    struct Identity: Equatable {
        let device: UInt64, inode: UInt64, mode: UInt32, size: Int64, modifiedSeconds: Int64, modifiedNanoseconds: Int64, changedSeconds: Int64, changedNanoseconds: Int64
        init(_ info: stat) {
            device = UInt64(truncatingIfNeeded: info.st_dev); inode = UInt64(info.st_ino); mode = UInt32(info.st_mode); size = Int64(info.st_size)
            #if canImport(Darwin)
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
            changedSeconds = Int64(info.st_ctimespec.tv_sec); changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
            #else
            modifiedSeconds = Int64(info.st_mtim.tv_sec); modifiedNanoseconds = Int64(info.st_mtim.tv_nsec)
            changedSeconds = Int64(info.st_ctim.tv_sec); changedNanoseconds = Int64(info.st_ctim.tv_nsec)
            #endif
        }
    }
    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        guard url.isFileURL, !url.path.contains("\0") else { throw AutomationContractError.invalidIdentity }
        return try readDescriptor(open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK), maximumBytes: maximumBytes)
    }
    /// A prepared case can have no attempt directory yet. Only ENOENT means absent;
    /// aliases, wrong types, ownership failures and unreadable directories remain errors.
    static func directoryExists(root: URL, relativePath: String, requirePrivateOwnership: Bool) throws -> Bool {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard root.isFileURL, !root.path.contains("\0"), !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw AutomationContractError.invalidIdentity
        }
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard directory >= 0 else { throw AutomationContractError.invalidIdentity }
        defer { close(directory) }
        if requirePrivateOwnership { try validatePrivateDirectory(directory) }
        for component in components {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            guard next >= 0 else {
                if errno == ENOENT { return false }
                throw AutomationContractError.invalidIdentity
            }
            close(directory); directory = next
            if requirePrivateOwnership { try validatePrivateDirectory(directory) }
        }
        return true
    }
    /// Descriptor-relative traversal prevents replaced directory symlinks escaping an authorised root.
    static func read(root: URL, relativePath: String, maximumBytes: Int, requirePrivateOwnership: Bool = false, identity: ((Identity) -> Void)? = nil) throws -> Data {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else { throw AutomationContractError.invalidIdentity }
        guard root.isFileURL, !root.path.contains("\0") else { throw AutomationContractError.invalidIdentity }
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard directory >= 0 else { throw AutomationContractError.invalidIdentity }
        defer { close(directory) }
        if requirePrivateOwnership { try validatePrivateDirectory(directory) }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            guard next >= 0 else { throw AutomationContractError.invalidIdentity }
            close(directory); directory = next
            if requirePrivateOwnership { try validatePrivateDirectory(directory) }
        }
        return try readDescriptor(openat(directory, components.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK), maximumBytes: maximumBytes, requirePrivateOwnership: requirePrivateOwnership, identity: identity)
    }
    private static func validatePrivateDirectory(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              info.st_mode & 0o022 == 0 else { throw AutomationContractError.invalidIdentity }
    }
    private static func readDescriptor(_ fd: Int32, maximumBytes: Int, requirePrivateOwnership: Bool = false, identity: ((Identity) -> Void)? = nil) throws -> Data {
        guard fd >= 0 else { throw AutomationContractError.invalidIdentity }
        guard maximumBytes > 0, maximumBytes < Int.max else { close(fd); throw AutomationContractError.invalidIdentity }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0,
              before.st_size <= maximumBytes else { close(fd); throw AutomationContractError.invalidIdentity }
        if requirePrivateOwnership, before.st_uid != getuid() || before.st_nlink != 1 || before.st_mode & 0o022 != 0 {
            close(fd); throw AutomationContractError.invalidIdentity
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        var after = stat()
        guard data.count <= maximumBytes, data.count == before.st_size, fstat(fd, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_mode == after.st_mode,
              before.st_size == after.st_size else { throw AutomationContractError.conflictingOperation }
        #if canImport(Darwin)
        guard before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw AutomationContractError.conflictingOperation }
        #else
        guard before.st_mtim.tv_sec == after.st_mtim.tv_sec, before.st_mtim.tv_nsec == after.st_mtim.tv_nsec,
              before.st_ctim.tv_sec == after.st_ctim.tv_sec, before.st_ctim.tv_nsec == after.st_ctim.tv_nsec else { throw AutomationContractError.conflictingOperation }
        #endif
        identity?(Identity(after))
        return data
    }
}
