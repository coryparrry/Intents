import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum IntentLabExecutableDigest {
    public static func hash(_ url: URL, maximumBytes: Int = 134_217_728) throws -> String {
        try hash(url, maximumBytes: maximumBytes, afterOpen: nil)
    }

    static func hash(_ url: URL, maximumBytes: Int, afterOpen: (() throws -> Void)?) throws -> String {
        guard url.isFileURL, maximumBytes > 0, maximumBytes <= 134_217_728 else { throw CocoaError(.fileReadCorruptFile) }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              (1...maximumBytes).contains(Int(before.st_size)) else { throw CocoaError(.fileReadCorruptFile) }
        try afterOpen?()
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var hasher = SHA256(), total = 0
        while let chunk = try handle.read(upToCount: min(65_536, maximumBytes - total + 1)), !chunk.isEmpty {
            guard chunk.count <= maximumBytes - total else { throw CocoaError(.fileReadTooLarge) }
            total += chunk.count; hasher.update(data: chunk)
        }
        var after = stat(), pathInfo = stat()
        guard fstat(descriptor, &after) == 0, lstat(url.path, &pathInfo) == 0,
              pathInfo.st_mode & S_IFMT == S_IFREG,
              pathInfo.st_dev == before.st_dev, pathInfo.st_ino == before.st_ino,
              total == before.st_size, before.st_size == after.st_size,
              stamp(before) == stamp(after) else { throw CocoaError(.fileReadCorruptFile) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func stamp(_ info: stat) -> String {
        #if canImport(Darwin)
        "\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        #else
        "\(info.st_mtim.tv_sec):\(info.st_mtim.tv_nsec):\(info.st_ctim.tv_sec):\(info.st_ctim.tv_nsec)"
        #endif
    }
}
