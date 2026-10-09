#if os(macOS) || os(Linux)
import Foundation
#if os(macOS)
import Darwin
#else
import Glibc
#endif

/// Owns write/close serialization while leaving the actor free to close a stalled pipe.
actor AutomationPipeWriter {
    private struct Frame {
        let id: UUID
        let data: Data
        let continuation: CheckedContinuation<Void, Error>
        var offset = 0
    }
    private let handle: FileHandle
    private var frames: [Frame] = []
    private var draining: Task<Void, Never>?
    private var closed = false
    private(set) var isBackpressured = false

    init(_ handle: FileHandle) throws {
        self.handle = handle
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw AutomationRPCError.disconnected }
        #if os(macOS)
        guard fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw AutomationRPCError.disconnected }
        #endif
    }
    func write(_ data: Data) async throws {
        try Task.checkCancellation()
        guard !closed else { throw AutomationRPCError.disconnected }
        guard frames.count < 64 else { throw AutomationRPCError.requestLimit }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                frames.append(.init(id: id, data: data, continuation: continuation))
                if draining == nil { draining = Task { await self.drain() } }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func close() {
        guard !closed else { return }
        closed = true
        isBackpressured = false
        draining?.cancel(); draining = nil
        let pending = frames; frames.removeAll()
        try? handle.close()
        for frame in pending { frame.continuation.resume(throwing: AutomationRPCError.disconnected) }
    }
    private func cancel(_ id: UUID) {
        guard let index = frames.firstIndex(where: { $0.id == id }) else { return }
        // A partially written frame cannot be removed without corrupting the stream.
        if frames[index].offset > 0 { close(); return }
        frames.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    private func drain() async {
        while !closed, !frames.isEmpty {
            let frame = frames[0]
            if frame.offset == frame.data.count {
                frames.removeFirst().continuation.resume(); continue
            }
            let result = frame.data.withUnsafeBytes { bytes in
                Self.writeBytes(handle.fileDescriptor, bytes.baseAddress!.advanced(by: frame.offset), min(65_536, frame.data.count - frame.offset))
            }
            if result.count > 0 { isBackpressured = false; frames[0].offset += result.count; continue }
            if result.error == EINTR { continue }
            if result.error == EAGAIN || result.error == EWOULDBLOCK {
                isBackpressured = true
                do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
            } else { close(); break }
        }
        draining = nil
    }
    private static func writeBytes(_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> (count: Int, error: Int32) {
        #if os(macOS)
        let result = Darwin.write(descriptor, bytes, count)
        return (result, errno)
        #else
        // Consume only this write's SIGPIPE, without changing process-wide signal policy.
        var mask = sigset_t(), old = sigset_t(), pending = sigset_t()
        sigemptyset(&mask); sigaddset(&mask, SIGPIPE)
        guard pthread_sigmask(SIG_BLOCK, &mask, &old) == 0 else { return (-1, EIO) }
        sigpending(&pending); let wasPending = sigismember(&pending, SIGPIPE) == 1
        let result = Glibc.write(descriptor, bytes, count), error = errno
        if result < 0, error == EPIPE, !wasPending {
            var zero = timespec(tv_sec: 0, tv_nsec: 0)
            _ = sigtimedwait(&mask, nil, &zero)
        }
        _ = pthread_sigmask(SIG_SETMASK, &old, nil)
        return (result, error)
        #endif
    }
}
#endif
