/// Stand-alone support emitted into the signed test target. Only the test target imports Apple's frameworks.
enum SiriStudioGeneratedSupport {
    static let source = #"""
    private struct StudioEvaluation: Evaluation {
        let name: String
        let scenarioID: String
        let revision: Int
        let turnIDs: [String]
        let samples: [SiriScenario]
        let setup: (@Sendable () async throws -> Void)?
        private let reports = StudioReports()

        var dataset: SiriScenarioLoader { SiriScenarioLoader { samples } }
        var evaluators: Evaluators { SiriExpectationEvaluator() }

        /// Uses Apple's standard metrics for Siri calls and replies.
        func aggregateMetrics(using aggregator: inout MetricsAggregator) {
            Self.computeSiriMetrics(into: &aggregator)
        }

        /// Runs the loader's original sample with its own reset and captures any available transcript.
        func subject(from sample: SiriScenario) async throws -> SiriScenarioSubject {
            guard let index = repeatIndex(of: sample) else { throw CocoaError(.validationMissingMandatoryProperty) }
            return try await reports.run(scenarioID: scenarioID, index: index, setup: setup, sample: sample, turnIDs: turnIDs)
        }

        /// Uses the original turn ID to identify a sample without relying on row order.
        private func repeatIndex(of sample: SiriScenario) -> Int? {
            guard let turn = sample.turns.first else { return nil }
            return samples.firstIndex { $0.turns.first?.id == turn.id }
        }

        /// Attaches reports from the test body, after the evaluation trait has completed.
        func record(_ result: EvaluationResult, metrics: [(String, Metric)]) async {
            for (index, bytes) in await reports.drain() {
                guard let payload = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else {
                    Issue.record("Siri Studio could not decode a recorded transcript.")
                    continue
                }
                attach(payload.merging(["repeatIndex": index], uniquingKeysWith: { _, new in new }),
                       kind: "report", suffix: "r\(index)")
            }
            let means = Dictionary(uniqueKeysWithValues: metrics.compactMap { name, metric in
                let mean = result.aggregateValue(.mean(of: metric))
                return (0...1).contains(mean) ? (name, mean) : nil
            })
            var summary: [String: Any] = [
                "metrics": means, "inferenceFailureCount": result.errors.inferenceFailureCount,
                "metricsNotFound": result.errors.metricsNotFound,
                "evaluatorFailureCount": result.errors.evaluatorFailureCount
            ]
            if let rows = perRepeat(result.detailed, metrics: metrics) { summary["perRepeat"] = rows }
            attach(summary, kind: "summary", suffix: "summary")
        }

        /// Matches typed rows to sample IDs; an unrecognized table falls back to aggregates.
        private func perRepeat(_ frame: DataFrame, metrics: [(String, Metric)]) -> [[String: Any]]? {
            guard frame.columns.contains(where: { $0.name == inputColumn.name && $0.wrappedElementType == SiriScenario.self }),
                  metrics.allSatisfy({ _, metric in
                      frame.columns.contains { $0.name == metric.name && $0.wrappedElementType == Metric.self }
                  }) else { return nil }
            var seen = Set<Int>()
            var rows: [[String: Any]] = []
            for (row, sample) in frame[inputColumn.name, SiriScenario.self].enumerated() {
                guard let sample, let index = repeatIndex(of: sample), seen.insert(index).inserted else { return nil }
                let values = Dictionary(uniqueKeysWithValues: metrics.compactMap { name, metric in
                    frame[metric.name, Metric.self][row]?.doubleValue.map { (name, $0) }
                })
                rows.append(["repeatIndex": index, "metrics": values])
            }
            return rows
        }

        /// Records UTF-8 JSON with the schema and frozen scenario identity.
        private func attach(_ payload: [String: Any], kind: String, suffix: String) {
            var object = payload
            object["schema"] = "dev.intents.siri-studio.\(kind)"
            object["version"] = 1
            object["scenarioID"] = scenarioID
            object["revision"] = revision
            do {
                let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                Attachment.record(String(decoding: bytes, as: UTF8.self), named: "siri-studio-\(scenarioID)-\(suffix).json")
            } catch {
                Issue.record("Siri Studio could not encode a report attachment.")
            }
        }
    }

    /// Gates setup plus Siri as one operation even if Evaluations schedules samples concurrently.
    private actor StudioReports {
        private var busy = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var reports: [Int: Data] = [:]

        /// Records a blocked setup, a blocked Siri start, or the transcript from a completed or partial run.
        func run(scenarioID: String, index: Int, setup: (@Sendable () async throws -> Void)?, sample: SiriScenario,
                 turnIDs: [String]) async throws -> SiriScenarioSubject {
            if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
            defer {
                if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
            }
            do {
                try Task.checkCancellation()
                progress(scenarioID, index: index)
                try await setup?()
            } catch {
                blocked(index, phase: "setup", error: error, count: turnIDs.count)
                throw error
            }
            let subject: SiriScenarioSubject
            do {
                subject = try await SiriService.run(scenario: sample)
            } catch {
                blocked(index, phase: "siri", error: error, count: turnIDs.count)
                throw error
            }
            let turns = zip(turnIDs, sample.turns).compactMap { id, userTurn -> [String: Any]? in
                guard let turn = subject.siriTranscript.turn(for: userTurn.id) else { return nil }
                return [
                    "turnID": id, "utterance": userTurn.utterance,
                    "invocations": turn.intentInvocations.map(invocation),
                    "foundEntities": turn.foundEntities.map { observation(String(describing: $0.value.identifier), at: $0.timestamp) },
                    "onScreenEntities": turn.onScreenEntities.map { observation(String(describing: $0.value.identifier), at: $0.timestamp) },
                    "loadedSkills": turn.loadedSkills.map { observation(String(describing: $0.value), at: $0.timestamp) },
                    "response": observation(turn.response.value, at: turn.response.timestamp)
                ]
            }
            save(index, ["status": "ran", "turnsAuthored": turnIDs.count, "turnsReached": turns.count, "turns": turns])
            return subject
        }

        /// Updates Studio progress when xcodebuild supplied an owned, local progress path.
        private func progress(_ id: String, index: Int) {
            guard let path = ProcessInfo.processInfo.environment["INTENTS_SIRI_PROGRESS"] else { return }
            do {
                let data = try JSONSerialization.data(withJSONObject: ["scenarioID": id, "repeatIndex": index])
                try data.write(to: URL(filePath: path), options: .atomic)
            } catch {
                // Progress is optional and never changes Apple's evaluation.
            }
        }

        /// Takes the accumulated reports and clears them for any later test iteration.
        func drain() -> [Int: Data] {
            defer { reports.removeAll() }
            return reports
        }

        /// Captures the phase and error for a run that did not start.
        private func blocked(_ index: Int, phase: String, error: any Error, count: Int) {
            let info = error as NSError
            save(index, ["status": "blocked", "turnsAuthored": count, "turnsReached": 0, "turns": [],
                         "blocked": ["phase": phase, "errorType": "\(info.domain) (\(info.code))", "message": error.localizedDescription]])
        }

        /// Encodes before crossing actor isolation, retaining any encoding failure as a test issue.
        private func save(_ index: Int, _ object: [String: Any]) {
            do { reports[index] = try JSONSerialization.data(withJSONObject: object) }
            catch { Issue.record("Siri Studio could not encode a transcript.") }
        }

        /// Preserves the public outcome flags and the argument and result display text.
        private func invocation(_ entry: SiriTranscript.Observation<SiriTranscript.IntentInvocation>) -> [String: Any] {
            let value = entry.value
            let outcome: String
            switch value.outcome {
            case .succeeded: outcome = "succeeded"
            case .awaitingConfirmation: outcome = "awaitingConfirmation"
            case .needsInput: outcome = "needsInput"
            case .failed: outcome = "failed"
            case .unknown: outcome = "unknown"
            case .unreported: outcome = "unreported"
            @unknown default: outcome = "unknown"
            }
            var data: [String: Any] = [
                "intent": value.intent.identifier, "bundleIdentifier": value.intent.bundleIdentifier,
                "arguments": value.arguments, "outcome": outcome, "ran": value.outcome.ran,
                "committed": value.outcome.committed, "timestamp": entry.timestamp.ISO8601Format()
            ]
            if let result = value.result { data["result"] = String(describing: result.value) }
            return data
        }

        /// Formats a timestamped text observation for local display.
        private func observation(_ text: String, at time: Date) -> [String: String] {
            ["text": text, "timestamp": time.ISO8601Format()]
        }
    }
    """#
}
