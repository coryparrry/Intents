import CryptoKit
import Foundation

struct EvaluationJudgeCalibrationGroup: Identifiable, Sendable {
    var partition: EvaluationJudgeCheckPartition
    var contractDigest: String
    var correctPasses = 0
    var falseFailures = 0
    var falsePasses = 0
    var correctFailures = 0
    var unavailable = 0
    var id: String { "\(partition.rawValue)/\(contractDigest)" }
    var humanPassCount: Int { correctPasses + falseFailures }
    var humanFailCount: Int { correctFailures + falsePasses }
    var falsePassRate: Double? { humanFailCount == 0 ? nil : Double(falsePasses) / Double(humanFailCount) }
    var falseFailureRate: Double? { humanPassCount == 0 ? nil : Double(falseFailures) / Double(humanPassCount) }
    var hasBothClasses: Bool { humanPassCount > 0 && humanFailCount > 0 }
}

extension EvaluationJudgeCheckReport {
    var calibrationGroups: [EvaluationJudgeCalibrationGroup] {
        var groups: [String: EvaluationJudgeCalibrationGroup] = [:]
        for result in results {
            let contract = result.example.scoringContract.flatMap { try? CanonicalJSON.data(for: $0, prettyPrinted: false) }
            let digest = contract.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "unknown"
            let partition = result.example.partition ?? .development
            let key = "\(partition.rawValue)/\(digest)"
            var group = groups[key] ?? .init(partition: partition, contractDigest: digest)
            if result.errorMessage != nil || digest == "unknown"
                || (result.actualStatus != .passed && result.actualStatus != .failed)
                || (result.example.expectedStatus != .passed && result.example.expectedStatus != .failed) {
                group.unavailable += 1
            } else if result.example.expectedStatus == .passed {
                if result.actualStatus == .passed { group.correctPasses += 1 } else { group.falseFailures += 1 }
            } else {
                if result.actualStatus == .failed { group.correctFailures += 1 } else { group.falsePasses += 1 }
            }
            groups[key] = group
        }
        return groups.values.sorted { $0.id < $1.id }
    }
}
