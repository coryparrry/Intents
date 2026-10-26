import Darwin
import Dispatch
import Foundation

/// Keep termination requests cooperative until the runner finishes owned cleanup.
@MainActor
final class NativeTestsSignals {
    private struct Registration {
        let number: Int32
        var previous: sigaction
        let source: DispatchSourceSignal
    }
    private var registrations: [Registration] = []

    /// Routes SIGINT and SIGTERM through a main-actor cancellation callback, restoring prior handlers if setup fails.
    init(cancel: @escaping @MainActor () -> Void) throws {
        do {
            for number in [SIGINT, SIGTERM] {
                var previous = sigaction()
                guard sigaction(number, nil, &previous) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                var ignored = sigaction()
                ignored.__sigaction_u.__sa_handler = SIG_IGN
                sigemptyset(&ignored.sa_mask)
                guard sigaction(number, &ignored, nil) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { Task { @MainActor in cancel() } }
                registrations.append(.init(number: number, previous: previous, source: source))
                source.resume()
            }
        } catch {
            restore()
            throw error
        }
    }

    /// Cancels signal sources and restores each saved signal action, clearing registrations for repeated cleanup.
    func restore() {
        for var registration in registrations {
            registration.source.cancel()
            sigaction(registration.number, &registration.previous, nil)
        }
        registrations.removeAll()
    }

    /// Installs cooperative cancellation handlers for the asynchronous operation and restores original handlers on every exit.
    static func whileRunning<T>(cancel: @escaping @MainActor () -> Void,
                                operation: @MainActor () async throws -> T) async throws -> T {
        let signals = try NativeTestsSignals(cancel: cancel)
        defer { signals.restore() }
        return try await operation()
    }
}
