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

    func restore() {
        for var registration in registrations {
            registration.source.cancel()
            sigaction(registration.number, &registration.previous, nil)
        }
        registrations.removeAll()
    }

    static func whileRunning<T>(cancel: @escaping @MainActor () -> Void,
                                operation: @MainActor () async throws -> T) async throws -> T {
        let signals = try NativeTestsSignals(cancel: cancel)
        defer { signals.restore() }
        return try await operation()
    }
}
