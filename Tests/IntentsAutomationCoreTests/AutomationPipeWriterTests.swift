#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationPipeWriterTests: XCTestCase, @unchecked Sendable {
    private func waitForBackpressure(_ writer: AutomationPipeWriter) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await writer.isBackpressured), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let stalled = await writer.isBackpressured; XCTAssertTrue(stalled)
    }
    func testCloseRemainsAvailableWhileLargeWriteIsStalled() async throws {
        let pipe = Pipe(), writer = try AutomationPipeWriter(pipe.fileHandleForWriting)
        defer { try? pipe.fileHandleForReading.close() }
        let send = Task { try await writer.write(Data(repeating: 65, count: 1_048_000)) }
        try await waitForBackpressure(writer)
        let start = ContinuousClock.now
        await writer.close()
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        do { try await send.value; XCTFail("Closed pipe accepted a stalled write") }
        catch { XCTAssertEqual(error as? AutomationRPCError, .disconnected) }
    }
    func testConcurrentLargeFramesDoNotInterleave() async throws {
        let pipe = Pipe(), writer = try AutomationPipeWriter(pipe.fileHandleForWriting)
        let reader = Task.detached { () -> Data in
            var data = Data()
            while let next = try? pipe.fileHandleForReading.read(upToCount: 65_536), !next.isEmpty { data.append(next) }
            try? pipe.fileHandleForReading.close(); return data
        }
        let a = Data(repeating: 65, count: 300_000), b = Data(repeating: 66, count: 300_000)
        let first = Task { try await writer.write(a) }, second = Task { try await writer.write(b) }
        do { try await first.value; try await second.value }
        catch { await writer.close(); _ = await reader.value; throw error }
        await writer.close()
        let received = await reader.value
        XCTAssertTrue(received == a + b || received == b + a)
    }
    func testCancellingPartialFrameFailsQueuedSendsAndRejectsNewWrites() async throws {
        let pipe = Pipe(), writer = try AutomationPipeWriter(pipe.fileHandleForWriting)
        defer { try? pipe.fileHandleForReading.close() }
        let partial = Task { try await writer.write(Data(repeating: 65, count: 1_048_000)) }
        try await waitForBackpressure(writer)
        let queued = Task { try await writer.write(Data(repeating: 66, count: 100)) }
        partial.cancel()
        do { try await partial.value; XCTFail("Cancelled partial frame completed") }
        catch { XCTAssertEqual(error as? AutomationRPCError, .disconnected) }
        do { try await queued.value; XCTFail("Queued frame survived corrupted stream") }
        catch { XCTAssertEqual(error as? AutomationRPCError, .disconnected) }
        do { try await writer.write(Data([67])); XCTFail("Closed stream accepted new write") }
        catch { XCTAssertEqual(error as? AutomationRPCError, .disconnected) }
    }
    func testReaderExitFailsPendingWriteWithoutSIGPIPE() async throws {
        let pipe = Pipe(), writer = try AutomationPipeWriter(pipe.fileHandleForWriting)
        let send = Task { try await writer.write(Data(repeating: 65, count: 1_048_000)) }
        try await waitForBackpressure(writer)
        try pipe.fileHandleForReading.close()
        do { try await send.value; XCTFail("Reader exit accepted pending write") }
        catch { XCTAssertEqual(error as? AutomationRPCError, .disconnected) }
        await writer.close()
    }
}
#endif
