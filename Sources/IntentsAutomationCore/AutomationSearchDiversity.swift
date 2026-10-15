import Foundation

/// Measurements of retained behaviour, not code coverage or a prediction of a future verdict.
public struct AutomationSearchDiversityMeasurement: Codable, Equatable, Sendable {
    public var caseDigest: String
    public var categories: [String]
    public var newCategories: [String]
    public var priorityNumerator: Int
    public var priorityDenominator: Int
}

/// Only the scheduler sees these facts. Expected values and assertion failures are
/// deliberately excluded; the controller receives its original frozen payload.
struct AutomationSearchDiversityQueue {
    private var seen = Set<String>()
    private var families: [AutomationMutationKind: (novel: Int, attempts: Int)] = [:]

    mutating func observeBaseline(_ report: AutomationAttemptReport) { seen.formUnion(Self.categories(report)) }

    func next(in pending: [AutomationMutationCase]) -> AutomationMutationCase? {
        pending.sorted { lhs, rhs in
            let leftSize = max(1, lhs.recipeIDs.count), rightSize = max(1, rhs.recipeIDs.count)
            if leftSize != rightSize { return leftSize < rightSize }
            let left = priority(lhs), right = priority(rhs)
            let leftRank = left.0 * right.1, rightRank = right.0 * left.1
            if leftRank != rightRank { return leftRank > rightRank }
            return lhs.frozen.digest < rhs.frozen.digest
        }.first
    }

    mutating func observe(_ report: AutomationAttemptReport, mutation: AutomationMutationCase) -> AutomationSearchDiversityMeasurement {
        let score = priority(mutation)
        let categories = Self.categories(report), novel = categories.filter { !seen.contains($0) }
        seen.formUnion(categories)
        for family in Set(mutation.kinds) {
            var history = families[family] ?? (novel: 0, attempts: 0)
            history.novel += novel.count; history.attempts += 1; families[family] = history
        }
        return .init(caseDigest: mutation.frozen.digest, categories: categories, newCategories: novel,
            priorityNumerator: score.0, priorityDenominator: score.1)
    }

    // Mean measured novel categories for a case's declared families. Unobserved
    // families receive one exploration point. Repeated behaviour lowers this mean.
    private func priority(_ mutation: AutomationMutationCase) -> (Int, Int) {
        var numerator = 0, denominator = 0
        for family in Set(mutation.kinds) {
            let history = families[family] ?? (novel: 1, attempts: 1)
            numerator += history.novel; denominator += history.attempts
        }
        return (numerator, max(1, denominator))
    }

    static func categories(_ report: AutomationAttemptReport) -> [String] {
        var categories = Set<String>()
        for receipt in report.receipts {
            let prefix = "route/" + receipt.route.rawValue
            categories.insert(prefix + "/dispatch/" + String(receipt.dispatched))
            categories.insert(prefix + "/completion/" + String(receipt.completed))
            for observation in receipt.observations where observation.fresh && observation.complete {
                categories.insert("state/" + observation.proof.rawValue + "/" + shape(observation.value))
            }
            for value in (receipt.verifiedOutputs ?? [:]).values {
                categories.insert("response/" + receipt.route.rawValue + "/" + shape(value))
            }
        }
        return Array(categories.sorted().prefix(256))
    }

    // Structural categories avoid treating a fresh UUID, fixture name, timestamp
    // or arbitrary response text as a new behaviour on every attempt.
    private static func shape(_ value: AutomationValue, depth: Int = 0) -> String {
        guard depth < 4 else { return "nested" }
        switch value {
        case .text(let text): return text.isEmpty ? "text.empty" : "text.present"
        case .bool(let value): return "bool." + String(value)
        case .integer(let value), .decimal(let value):
            return value == "0" || value == "0.0" ? "number.zero" : value.hasPrefix("-") ? "number.negative" : "number.positive"
        case .enumeration(let type, let value): return "enum." + type + "." + value
        case .entity(let type, _): return "entity." + type
        case .date: return "date"
        case .artifact: return "artifact"
        case .null: return "null"
        case .omission: return "omission"
        case .array(let values):
            let elements = Set(values.prefix(32).map { shape($0, depth: depth + 1) }).sorted().joined(separator: ",")
            return "array." + (values.isEmpty ? "empty" : values.count == 1 ? "one" : "many") + "/" + AutomationArtifactRegistry.digest(Data(elements.utf8))
        case .object(let values):
            let properties = values.keys.sorted().prefix(32).map { $0 + ":" + shape(values[$0]!, depth: depth + 1) }.joined(separator: ",")
            return "object/" + AutomationArtifactRegistry.digest(Data(properties.utf8))
        }
    }
}

extension AutomationUIFailureSearchRecord {
    /// Old archives retain their original static order; new records replay every
    /// priority and novelty measurement from retained facts to reject tampering.
    func validateDiscoveryOrder() throws {
        let discoveries = report.attempts.filter { $0.stage == .discovery }
        guard let measurements = report.discoveryDiversity else {
            let ordered = mutations.sorted { $0.recipeIDs.count == $1.recipeIDs.count ? $0.frozen.digest < $1.frozen.digest : $0.recipeIDs.count < $1.recipeIDs.count }
            guard discoveries.map(\.caseDigest) == ordered.prefix(discoveries.count).map({ $0.frozen.digest }) else { throw AutomationContractError.conflictingOperation }
            return
        }
        guard measurements.count == discoveries.count else { throw AutomationContractError.conflictingOperation }
        var queue = AutomationSearchDiversityQueue(), pending = mutations
        for attempt in report.attempts where attempt.stage == .baseline { queue.observeBaseline(attempt.report) }
        for (attempt, measurement) in zip(discoveries, measurements) {
            guard let selected = queue.next(in: pending), selected.frozen.digest == attempt.caseDigest,
                  queue.observe(attempt.report, mutation: selected) == measurement else { throw AutomationContractError.conflictingOperation }
            pending.removeAll { $0.frozen.digest == selected.frozen.digest }
        }
    }
}
