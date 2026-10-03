import Foundation

public struct ProductionSchedule: Codable, Identifiable, Sendable {
    public var id: UUID
    public var templateJobID: UUID
    public var intervalSeconds: Double
    public var nextRun: Date
    public var remainingRuns: Int
    public var paused: Bool
    public init(id: UUID = UUID(), templateJobID: UUID, intervalSeconds: Double, nextRun: Date = Date(), remainingRuns: Int = 1, paused: Bool = false) {
        self.id = id; self.templateJobID = templateJobID; self.intervalSeconds = intervalSeconds
        self.nextRun = nextRun; self.remainingRuns = remainingRuns; self.paused = paused
    }
}
extension ProductionStorage {
    public func saveSchedule(_ schedule: ProductionSchedule) throws {
        _ = try loadJob(schedule.templateJobID)
        guard schedule.intervalSeconds.isFinite, (60...31_536_000).contains(schedule.intervalSeconds),
              (0...1_000).contains(schedule.remainingRuns), schedule.nextRun.timeIntervalSince1970.isFinite else {
            throw ProductionFailure.invalid("Schedules need a finite interval and at most 1,000 future runs.")
        }
        try transaction { try ProductionCodec.write(schedule, to: root.appendingPathComponent("Schedules/\(schedule.id.uuidString).json")) }
    }
    public func schedules() throws -> [ProductionSchedule] {
        try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Schedules"), includingPropertiesForKeys: nil)
            .map { try ProductionCodec.read(ProductionSchedule.self, from: $0, maximumBytes: 10_000) }
    }
    /// Deterministic job IDs make retries safe if schedule advancement is interrupted.
    public func tickSchedules(now: Date = Date()) throws -> [UUID] {
        var launched: [UUID] = []
        for schedule in try schedules() where !schedule.paused && schedule.remainingRuns > 0 && (schedule.nextRun.timeIntervalSince1970*1000).rounded() <= (now.timeIntervalSince1970*1000).rounded() {
            try transaction {
                let path = root.appendingPathComponent("Schedules/\(schedule.id.uuidString).json")
                var current = try ProductionCodec.read(ProductionSchedule.self, from: path, maximumBytes: 10_000)
                guard current.nextRun == schedule.nextRun, current.remainingRuns > 0, !current.paused else { return }
                let template = try loadJob(current.templateJobID)
                let id = ProductionCodec.stableID("schedule/\(current.id)/\(current.nextRun.timeIntervalSince1970)")
                var job = template
                job.id = id; job.name += " · scheduled"; job.createdAt = current.nextRun; job.revision = ""
                job.revision = ProductionCodec.digest(try ProductionCodec.encode(job))
                _ = try installJob(job)
                current.remainingRuns -= 1; current.nextRun = now.addingTimeInterval(current.intervalSeconds)
                try ProductionCodec.write(current, to: path)
                launched.append(id)
            }
        }
        return launched
    }
}
