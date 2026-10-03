import Foundation
import CryptoKit

private struct RateAccumulator {
    var rate = ProductionRate()
    var sources: [String: Bool] = [:]
    mutating func add(_ record: ProductionRecord, outcome: ProductionOutcome) {
        rate.samples += 1
        switch outcome { case .passed: rate.passed += 1; case .failed: rate.failed += 1; case .error: rate.errors += 1
        case .unscored: rate.unscored += 1; case .needsEvidence: rate.uncertain += 1 }
        sources[record.sourceID] = (sources[record.sourceID] ?? true) && outcome == .passed
    }
    var summary: ProductionRate {
        var result = rate; result.distinctSources = sources.count; result.passingSources = sources.values.filter { $0 }.count
        if result.distinctSources > 0 {
            let n = Double(result.distinctSources), p = Double(result.passingSources) / n, z = 1.959963984540054
            let denominator = 1 + z*z/n, centre = (p + z*z/(2*n))/denominator
            let margin = z * sqrt((p*(1-p)+z*z/(4*n))/n)/denominator
            result.lower95 = max(0, centre-margin); result.upper95 = min(1, centre+margin)
        }
        return result
    }
}

extension ProductionStorage {
    public func records(jobID: UUID, offset: Int = 0, limit: Int = 50) throws -> [ProductionRecord] {
        guard offset >= 0, (1...100).contains(limit) else { throw ProductionFailure.invalid("Result page must contain 1–100 rows.") }
        let job = try loadJob(jobID); var result: [ProductionRecord] = [], seen = 0
        for i in 0..<chunkCount(job) {
            let chunk = try chunk(job, index: i)
            for record in chunk.records.values.sorted(by: { $0.slot < $1.slot }) {
                if seen >= offset { result.append(record); if result.count == limit { return result } }; seen += 1
            }
        }
        return result
    }
    public func report(jobID: UUID, includeBaseline: Bool = true) throws -> ProductionReport {
        try transaction { try makeReport(jobID: jobID, includeBaseline: includeBaseline) }
    }
    // Caller holds the transaction for control, results, reviews and baseline evidence.
    func makeReport(jobID: UUID, includeBaseline: Bool) throws -> ProductionReport {
        let job = try loadJob(jobID)
        let reader = try ProductionDatasetReader(storage: self, revision: job.datasetRevision)
        let dataset = reader.dataset, control = try auditedCostControl(job)
        var total = RateAccumulator(), groups: [String: RateAccumulator] = [:], histogram: [Int: Int] = [:]
        var unavailableLatency = 0
        var latencySum = 0.0
        var cost = 0.0, missingCost = 0, completed = 0, reviewed = 0, latencyCount = 0
        var critical: [String: Bool] = [:], required: [String: Bool] = [:]
        var evidenceHash = SHA256()
        evidenceHash.update(data: Data(job.revision.utf8))
        evidenceHash.update(data: try ProductionCodec.encode(control))
        var hasActiveLease = false
        for i in 0..<chunkCount(job) {
            let chunk = try chunk(job, index: i)
            hasActiveLease = hasActiveLease || (chunk.lease.map { $0.expiresAt > Date() } ?? false)
            for record in chunk.records.values.sorted(by: { $0.slot < $1.slot }) {
                let request = try request(job, slot: record.slot, reader: reader)
                try validateResponse(record.response, requestID: request.requestID)
                guard record.sourceID == request.example.sourceID, record.exampleID == request.example.id,
                      record.partition == request.example.partition, record.metadata == request.example.metadata,
                      record.targetIndex == request.targetIndex, record.repetition == request.repetition,
                      job.configuration.targets[record.targetIndex].matches(record.worker) else {
                    throw ProductionFailure.integrity("Result provenance does not match its frozen input/target.")
                }
                let review = try readReview(jobID: job.id, requestID: record.response.requestID)
                evidenceHash.update(data: try ProductionCodec.encode(record))
                evidenceHash.update(data: try ProductionCodec.encode(review.events))
                let response = review.response ?? record.response, outcome = review.outcome ?? response.outcome
                try validateResponse(response, requestID: request.requestID)
                if review.outcome != nil || review.response != nil { reviewed += 1 }
                completed += 1; total.add(record, outcome: outcome)
                var dimensions = record.metadata.filter { entry in ["task", "locale", "language", "coverage", "sampling"].contains(entry.key)
                    || job.configuration.gate.requiredCohorts[entry.key] != nil
                    || job.configuration.gate.cohortMinimumPassRates.keys.contains(where: { $0.hasPrefix(entry.key + "=") }) }
                dimensions["platform"] = record.worker.platform; dimensions["os"] = record.worker.operatingSystem
                dimensions["model"] = record.worker.model; dimensions["deviceLocale"] = record.worker.locale; dimensions["hardware"] = record.worker.hardware; dimensions["target"] = String(record.targetIndex)
                dimensions["partition"] = record.partition.rawValue
                for (key, value) in dimensions {
                    let name = "\(key)=\(value)"; var group = groups[name] ?? RateAccumulator(); group.add(record, outcome: outcome); groups[name] = group
                }
                guard groups.count <= 2_000 else { throw ProductionFailure.invalid("Cohort cardinality exceeds 2,000. Use bounded metadata dimensions.") }
                if let amount = response.cost { cost += amount } else { missingCost += 1 }
                if response.latencyAvailable == false { unavailableLatency += 1 }
                if response.latencyAvailable != false, ![.error, .needsEvidence].contains(outcome) {
                    let bucket = Int(ceil(log2(max(1, response.latencyMilliseconds))*32))
                    histogram[bucket, default: 0] += 1; latencyCount += 1; latencySum += response.latencyMilliseconds
                }
                if job.configuration.gate.criticalSourceIDs.contains(record.sourceID) {
                    critical[record.sourceID] = (critical[record.sourceID] ?? true) && outcome == .passed
                }
                for (key,value) in job.configuration.gate.requiredCohorts where dimensions[key] == value { required["\(key)=\(value)"] = true }
            }
        }
        let counts = total.summary, cohorts = groups.mapValues(\.summary)
        var p95: Double?, traversed = 0
        for bucket in histogram.keys.sorted() {
            traversed += histogram[bucket] ?? 0
            if traversed >= Int(ceil(Double(latencyCount)*0.95)) { p95 = pow(2, Double(bucket)/32); break }
        }
        let average = latencyCount > 0 ? latencySum/Double(latencyCount) : nil
        var baselineCohorts: [String: Double] = [:]
        var issues: [String] = []
        var exit = 0
        if completed != job.plannedCount || counts.unscored > 0 || counts.uncertain > 0 || counts.passed + counts.failed == 0 || control.cancelled {
            issues.append("Missing, unscored or uncertain responses cannot qualify this job."); exit = 20
        }
        if counts.errors > job.configuration.gate.maximumErrors { issues.append("Execution errors exceed the permitted limit."); if exit == 0 { exit = 30 } }
        if let rate = counts.passRate, rate < job.configuration.gate.minimumPassRate { issues.append("Pass rate is below the required threshold."); if exit == 0 { exit = 10 } }
        if (job.configuration.gate.maximumAverageMilliseconds != nil || job.configuration.gate.maximumP95Milliseconds != nil) && (unavailableLatency > 0 || p95 == nil) { issues.append("Required latency evidence is unavailable."); exit = 20 }
        if let maximum = job.configuration.gate.maximumAverageMilliseconds, let average, average > maximum { issues.append("Average latency exceeds the required limit."); if exit == 0 { exit = 10 } }
        if let maximum = job.configuration.gate.maximumP95Milliseconds, let p95, p95 > maximum { issues.append("P95 latency exceeds the required limit."); if exit == 0 { exit = 10 } }
        for source in job.configuration.gate.criticalSourceIDs where critical[source] != true { issues.append("Critical source \(source) did not pass every trial."); if exit == 0 { exit = 10 } }
        for (key,value) in job.configuration.gate.requiredCohorts where required["\(key)=\(value)"] != true { issues.append("Required cohort \(key)=\(value) is missing."); exit = 20 }
        for (key,threshold) in job.configuration.gate.cohortMinimumPassRates {
            guard let rate = cohorts[key]?.passRate else { issues.append("Required cohort \(key) has no scored evidence."); exit = 20; continue }
            if rate < threshold { issues.append("Cohort \(key) falls below its threshold."); if exit == 0 { exit = 10 } }
        }
        if job.configuration.maximumCost != nil { cost = control.reportedCost }
        if let maximum = job.configuration.maximumCost, missingCost > 0 || cost > maximum || !control.costReservations.isEmpty { issues.append("Cost evidence is missing or exceeds the budget."); exit = 20 }
        let eligible = exit == 0 && counts.errors == 0 && !hasActiveLease && !control.paused && !control.cancelled
        let evidenceRevision = evidenceHash.finalize().map { String(format: "%02x", $0) }.joined()
        let approval = try readBaselineApproval(job)
        let currentApproval = eligible && approval?.evidenceRevision == evidenceRevision ? approval : nil
        var baselineRate: Double?
        if includeBaseline, let baselineID = job.configuration.baselineJobID {
            let baseline = try makeReport(jobID: baselineID, includeBaseline: false)
            guard baseline.job.datasetRevision == job.datasetRevision, baseline.job.configuration.scoringRevision == job.configuration.scoringRevision,
                  baseline.job.configuration.targets == job.configuration.targets, baseline.job.configuration.repetitions == job.configuration.repetitions,
                  baseline.job.id != job.id else {
                throw ProductionFailure.integrity("Baseline evidence is incompatible.")
            }
            if baseline.phase != "completed" || baseline.completed != baseline.planned
                || baseline.counts.unscored > 0 || baseline.counts.uncertain > 0 || baseline.counts.errors > 0 {
                issues.append("Baseline evidence is incomplete, paused or cancelled."); exit = 20
            } else if job.configuration.gate.requireBaseline && baseline.baselineApproval == nil {
                issues.append("An explicit approval of the current baseline evidence is required."); exit = 20
            } else {
                baselineRate = baseline.counts.passRate
                baselineCohorts = baseline.cohorts.compactMapValues(\.passRate)
                if let before = baselineRate, let after = counts.passRate, before-after > job.configuration.gate.maximumPassRateRegression {
                    issues.append("Pass rate regressed beyond the approved limit."); if exit == 0 { exit = 10 }
                }
            }
        } else if includeBaseline && job.configuration.gate.requireBaseline { issues.append("An approved compatible baseline is required."); exit = 20 }
        let phase = control.cancelled ? "cancelled" : control.paused ? "paused" : completed == job.plannedCount ? "completed" : "pending"
        let notice = dataset.sampling == .random ? "Random-source sampling; representativeness depends on the supplied sampling frame."
            : "Curated/targeted examples measure this dataset, not the production failure rate."
        return .init(job: job, dataset: dataset, completed: completed, planned: job.plannedCount, counts: counts, cohorts: cohorts,
                     averageMilliseconds: average, baselineCohortPassRates: baselineCohorts, p95UpperMilliseconds: p95, reportedCost: cost, missingCostCount: missingCost, phase: phase, exitCode: exit,
                     issues: issues, baselinePassRate: baselineRate, reviewedCount: reviewed, samplingNotice: notice,
                     evidenceRevision: evidenceRevision, baselineEligible: eligible, baselineApproval: currentApproval)
    }
}

extension ProductionStorage {
    public func record(jobID: UUID, slot: Int) throws -> ProductionRecord {
        let job = try loadJob(jobID)
        guard (0..<job.plannedCount).contains(slot), let record = try chunk(job,index:slot/job.configuration.chunkSize).records[slot] else {
            throw ProductionFailure.invalid("Completed result slot is unavailable.")
        }
        return record
    }
}
