#if os(macOS) || os(Linux)
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A private stdin socket avoids SIGPIPE and blocking writes during startup cancellation.
// One run owns this socket; stopOwned only terminates the captured child.
final class AutomationCommandGateInput: @unchecked Sendable {
    static let maximumPrivateFrameBytes = 131_072
    private var childFD: Int32 = -1
    private var parentFD: Int32 = -1
    var childHandle: FileHandle { FileHandle(fileDescriptor: childFD, closeOnDealloc: false) }
    init() throws {
        var pair = [Int32](repeating: -1, count: 2)
        #if canImport(Darwin)
        let kind = SOCK_STREAM
        #else
        let kind = Int32(SOCK_STREAM.rawValue)
        #endif
        guard socketpair(AF_UNIX, kind, 0, &pair) == 0 else { throw AutomationContractError.invalidIdentity }
        childFD = pair[0]; parentFD = pair[1]
        guard fcntl(childFD, F_SETFD, FD_CLOEXEC) == 0, fcntl(parentFD, F_SETFD, FD_CLOEXEC) == 0 else {
            closeBoth(); throw AutomationContractError.invalidIdentity
        }
        let parentFlags = fcntl(parentFD, F_GETFL)
        guard parentFlags >= 0, fcntl(parentFD, F_SETFL, parentFlags | O_NONBLOCK) == 0 else {
            closeBoth(); throw AutomationContractError.invalidIdentity
        }
        #if canImport(Darwin)
        var enabled: Int32 = 1
        guard setsockopt(parentFD, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            closeBoth(); throw AutomationContractError.invalidIdentity
        }
        #endif
    }
    func childStarted() { if childFD >= 0 { close(childFD); childFD = -1 } }
    func acknowledge(_ data: Data, keepOpen: Bool = false, deadline: ContinuousClock.Instant,
                     isolation: isolated (any Actor)? = #isolation, beforeWrite: () throws -> Void) async throws {
        guard !data.isEmpty, data.count <= 4096, data.last == 10 else { throw AutomationContractError.invalidIdentity }
        do {
            try await transmit(data, deadline: deadline, isolation: isolation, beforeWrite: beforeWrite)
            if !keepOpen { closeParent() }
        } catch { closeParent(); throw error }
    }
    func writePrivateFrame(_ data: Data, deadline: ContinuousClock.Instant,
                           isolation: isolated (any Actor)? = #isolation, beforeWrite: () throws -> Void) async throws {
        defer { closeParent() }
        try Self.validatePrivateFrame(data)
        try await transmit(data, deadline: deadline, isolation: isolation, beforeWrite: beforeWrite)
    }
    private func transmit(_ bytes: Data, deadline: ContinuousClock.Instant,
                          isolation: isolated (any Actor)? = #isolation, beforeWrite: () throws -> Void) async throws {
        #if canImport(Darwin)
        let flags = MSG_DONTWAIT
        #else
        let flags = MSG_DONTWAIT | MSG_NOSIGNAL
        #endif
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            try beforeWrite()
            guard parentFD >= 0, ContinuousClock.now < deadline else { throw AutomationContractError.terminationUnverified }
            let count = bytes.withUnsafeBytes { send(parentFD, $0.baseAddress!.advanced(by: offset), $0.count - offset, flags) }
            if count > 0 { offset += count; continue }
            if count < 0 && errno == EINTR { continue }
            guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else { throw AutomationContractError.terminationUnverified }
            // Suspend so the command actor can process independent stop/revocation requests.
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    private func closeParent() { if parentFD >= 0 { close(parentFD); parentFD = -1 } }
    static func validatePrivateFrame(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximumPrivateFrameBytes, data.last == 10,
              !data.dropLast().contains(10) else { throw AutomationContractError.invalidIdentity }
    }
    private func closeBoth() {
        if childFD >= 0 { close(childFD); childFD = -1 }
        if parentFD >= 0 { close(parentFD); parentFD = -1 }
    }
    deinit { closeBoth() }
}
#endif
