import Foundation

/// Non-Codable, manager-issued current lease view for synchronous native dispatch.
/// Durable leases additionally reread the same locked store immediately at the gate.
final class AutomationNativeInputLeaseFence: @unchecked Sendable {
    let lease: AutomationDeviceLeaseManager.Lease
    private let lock = NSLock()
    private var live = true
    private let persisted: (@Sendable () -> Bool)?
    init(lease: AutomationDeviceLeaseManager.Lease, persisted: (@Sendable () -> Bool)?) {
        self.lease = lease; self.persisted = persisted
    }
    var isCurrent: Bool {
        guard lock.withLock({ live }), persisted?() ?? true else { return false }
        return lock.withLock { live }
    }
    func invalidate() { lock.withLock { live = false } }
}
