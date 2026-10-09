import CryptoKit
import Foundation
import XCTest
@testable import IntentLabContracts
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class IntentLabExecutableDigestTests: XCTestCase {
    func testDescriptorHashMatchesBytesAndRejectsOversizeAndNonregularFiles() throws {
        try withFile { file in
            let bytes = Data("real executable bytes".utf8)
            try bytes.write(to: file)
            XCTAssertEqual(try IntentLabExecutableDigest.hash(file, maximumBytes: bytes.count), SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            XCTAssertThrowsError(try IntentLabExecutableDigest.hash(file, maximumBytes: bytes.count - 1))
            let alias = file.deletingLastPathComponent().appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
            XCTAssertThrowsError(try IntentLabExecutableDigest.hash(alias))
            let fifo = file.deletingLastPathComponent().appendingPathComponent("fifo")
            XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
            XCTAssertThrowsError(try IntentLabExecutableDigest.hash(fifo))
        }
    }
    func testGrowthReplacementAndContentDriftCannotHashDifferentInspectedBytes() throws {
        try withFile { file in
            try Data(repeating: 1, count: 8).write(to: file)
            XCTAssertThrowsError(try IntentLabExecutableDigest.hash(file, maximumBytes: 8, afterOpen: {
                let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: Data([2]))
            }))
            try Data(repeating: 1, count: 8).write(to: file)
            XCTAssertThrowsError(try IntentLabExecutableDigest.hash(file, maximumBytes: 8, afterOpen: {
                try Data(repeating: 2, count: 8).write(to: file, options: .atomic)
            }))
            try Data(repeating: 1, count: 8).write(to: file)
            XCTAssertThrowsError(try IntentLabExecutableDigest.hash(file, maximumBytes: 8, afterOpen: {
                let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
                try handle.write(contentsOf: Data(repeating: 2, count: 8))
            }))
        }
    }
    private func withFile(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("executable"))
    }
}
