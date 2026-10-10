import Foundation

/// One shared budget per whole capture/replay pass, including all granted trees.
struct AutomationSourceReadBudget {
    struct Limits {
        let entries: Int
        let bytes: Int
        static let standard = Self(entries: 100_000, bytes: 2_147_483_648)
    }
    let limits: Limits
    private(set) var entries = 0
    private(set) var bytes = 0
    init(limits: Limits) throws {
        guard (1...100_000).contains(limits.entries), (1...2_147_483_648).contains(limits.bytes) else { throw AutomationContractError.invalidIdentity }
        self.limits = limits
    }
    func requireAvailable() throws {
        guard entries < limits.entries, bytes < limits.bytes else { throw exceeded() }
    }
    mutating func entry() throws {
        guard entries < limits.entries else { throw exceeded() }; entries += 1
    }
    func readLimit(size: Int) throws -> Int {
        guard size >= 0, size <= 536_870_912, size <= limits.bytes - bytes, bytes < limits.bytes else { throw exceeded() }
        return min(536_870_912, limits.bytes - bytes)
    }
    mutating func consume(bytes count: Int) throws {
        guard count >= 0, count <= limits.bytes - bytes else { throw exceeded() }; bytes += count
    }
    private func exceeded() -> AutomationContractError { .invalidPlan("Source snapshot exceeds its shared entry/byte budget") }
}
