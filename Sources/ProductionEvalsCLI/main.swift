import Foundation
import ProductionEvals
#if canImport(FoundationModels)
import FoundationModels
#endif

struct TextWorkerSettings: Codable, Sendable {
    var kind = "foundation-models"
    var instructions = ""
    var scoring = "collect"
}

struct Options {
    let command: String
    let values: [String: String]
    init(_ arguments: [String]) throws {
        guard let command = arguments.first else { throw ProductionFailure.invalid(Self.help) }
        self.command = command; var result: [String:String] = [:]; var i = 1
        let flags: Set<String> = ["confirm-redacted", "production-data", "native", "captured", "poll", "json", "paused"]
        while i < arguments.count {
            let key = arguments[i]
            guard key.hasPrefix("--"), result[String(key.dropFirst(2))] == nil else { throw ProductionFailure.invalid("Invalid or duplicate argument: \(key)") }
            let name = String(key.dropFirst(2))
            if flags.contains(name) { result[name] = "true"; i += 1 }
            else {
                guard i+1 < arguments.count, !arguments[i+1].hasPrefix("--") else { throw ProductionFailure.invalid("Missing value for \(key)") }
                result[name] = arguments[i+1]; i += 2
            }
        }
        let allowed: [String: Set<String>] = [
            "import": ["file","name","version","sampling","production-data","confirm-redacted"],
            "clone": ["job","name","baseline"], "datasets": [], "jobs": [], "workers": [], "tick": [],
            "job": ["dataset","name","native","captured","instructions","scoring","executor","settings","repetitions","attempts","timeout","budget-seconds","safety","max-cost","cost-per-attempt","targets","policy","baseline"],
            "worker": ["worker-id","native","captured","executor","descriptor","job","poll","limit"],
            "report": ["job","output"], "export": ["job","output"], "results": ["job","offset","limit"],
            "pause": ["job"], "resume": ["job"], "cancel": ["job"],
            "review": ["job","slot","reviewer","verdict","note"], "adjudicate": ["job","slot","reviewer","verdict","note"],
            "assign": ["job","slot","reviewer","assignee","note"], "reconcile": ["job","slot","reviewer","result","note"],
            "schedule": ["job","interval","runs","paused"]]
        guard let permitted = allowed[command], Set(result.keys).subtracting(permitted.union(["storage"])).isEmpty else { throw ProductionFailure.invalid("Unknown command or option.\n" + Self.help) }
        if command == "job" || command == "worker" {
            guard ["native","captured","executor"].filter({ result[$0] != nil }).count == 1 else { throw ProductionFailure.invalid("Choose exactly one execution backend.") }
        }
        values = result
    }
    func required(_ key: String) throws -> String { guard let value = values[key], !value.isEmpty else { throw ProductionFailure.invalid("Missing --\(key)") }; return value }
    func url(_ key: String) throws -> URL { let value = try required(key); guard value.hasPrefix("/") else { throw ProductionFailure.invalid("--\(key) must be an absolute path.") }; return URL(fileURLWithPath: value) }
    func uuid(_ key: String) throws -> UUID { guard let value = UUID(uuidString: try required(key)) else { throw ProductionFailure.invalid("Invalid --\(key) UUID.") }; return value }
    func integer(_ key: String, default fallback: Int) throws -> Int { guard let value = values[key] else { return fallback }; guard let number = Int(value) else { throw ProductionFailure.invalid("Invalid integer --\(key)") }; return number }
    func number(_ key: String, default fallback: Double) throws -> Double { guard let value = values[key] else { return fallback }; guard let number = Double(value), number.isFinite else { throw ProductionFailure.invalid("Invalid finite number --\(key)") }; return number }
    static let help = """
    intents-evals <command> --storage /absolute/directory [options]
      import --file /examples.jsonl --name NAME --version VERSION [--sampling curated|random|targeted]
             [--production-data --confirm-redacted]
      datasets | jobs | workers
      clone --job UUID --name NAME [--baseline UUID]
      job --dataset REVISION --name NAME (--captured | --native [--scoring exact|contains|collect] [--instructions TEXT]
          | --executor /trusted/executable [--settings /settings.json]) [--repetitions N]
          [--targets /targets.json] [--policy /policy.json] [--baseline UUID] [--safety inference|idempotent|sideEffects]
          [--attempts N] [--timeout SECONDS] [--budget-seconds SECONDS] [--max-cost N --cost-per-attempt N]
      worker --worker-id NAME (--captured | --native | --executor /trusted/executable --descriptor /worker.json)
             [--job UUID] [--poll] [--limit N]
      export --job UUID --output /new-evidence-directory
      report --job UUID [--output /report.json]   (exit 0 pass, 10 regression, 20 incomplete, 30 execution error)
      results --job UUID [--offset N --limit N]
      pause | resume | cancel --job UUID
      review --job UUID --slot N --reviewer NAME --verdict passed|failed|needsEvidence --note TEXT
      assign --job UUID --slot N --reviewer NAME --assignee NAME --note TEXT
      adjudicate --job UUID --slot N --reviewer NAME --verdict passed|failed|needsEvidence --note TEXT
      reconcile --job UUID --slot N --reviewer NAME --result /verified-response.json --note TEXT
      schedule --job UUID --interval SECONDS --runs N [--paused]
      tick
    Storage and worker provenance are local/trusted; they are not hardware attestation.
    """
}

@main
struct ProductionEvalsCLI {
    static func main() async {
        do { try await run() } catch { FileHandle.standardError.write(Data(("intents-evals: \(error.localizedDescription)\n").utf8)); exit(30) }
    }
    static func printJSON<T: Encodable>(_ value: T) throws { FileHandle.standardOutput.write(try ProductionCodec.encode(value)); print("") }
    static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments == ["--help"] { print(Options.help); return }
        let options = try Options(arguments), storage = try ProductionStorage(root: options.url("storage"))
        switch options.command {
        case "import":
            guard let sampling = ProductionSampling(rawValue: options.values["sampling"] ?? "curated") else { throw ProductionFailure.invalid("Invalid sampling method.") }
            try printJSON(storage.importDataset(from: options.url("file"), name: options.required("name"), version: options.required("version"),
                sampling: sampling, productionData: options.values["production-data"] != nil, redactionConfirmed: options.values["confirm-redacted"] != nil))
        case "datasets": try printJSON(storage.datasets())
        case "jobs": try printJSON(storage.jobs())
        case "workers": try printJSON(storage.workers())
        case "clone":
            let source = try storage.loadJob(options.uuid("job")); var configuration = source.configuration
            if options.values["baseline"] != nil { configuration.baselineJobID = try options.uuid("baseline") }
            try printJSON(storage.createJob(name: options.required("name"), datasetRevision: source.datasetRevision, configuration: configuration))
        case "export": try storage.exportJob(options.uuid("job"), to: options.url("output"))
        case "job":
            if options.values["captured"] != nil {
                guard Set(options.values.keys).isSubset(of: ["storage","captured","dataset","name"]) else { throw ProductionFailure.invalid("Captured review has one trial per original output; configure review gates after import using a scored worker if needed.") }
                try printJSON(storage.createCapturedJob(name: options.required("name"), datasetRevision: options.required("dataset"))); return
            }
            let context: Data, scoringRevision: String
            if options.values["native"] != nil {
                var settings = TextWorkerSettings(); settings.instructions = options.values["instructions"] ?? ""
                settings.scoring = options.values["scoring"] ?? "collect"
                guard ["exact", "contains", "collect"].contains(settings.scoring) else { throw ProductionFailure.invalid("Unsupported native text scoring.") }
                context = try ProductionCodec.encode(settings); scoringRevision = ProductionCodec.digest(Data(("text-scoring-v1/" + settings.scoring).utf8))
            } else {
                let executable = try ProductionCommandExecutor(executable: options.url("executor"))
                let settings = try options.values["settings"].map { _ in try Data(contentsOf: options.url("settings")) }
                context = try ProductionCodec.encode(ProductionCommandContext(executableDigest: executable.executableDigest, settings: settings))
                scoringRevision = ProductionCodec.digest(Data(executable.executableDigest.utf8) + (settings ?? Data()))
            }
            var configuration = ProductionJobConfiguration(scoringRevision: scoringRevision, executionRevision: ProductionCodec.digest(context), executionContext: context)
            configuration.repetitions = try options.integer("repetitions", default: 1)
            configuration.maximumAttempts = try options.integer("attempts", default: 2)
            configuration.timeoutSeconds = try options.number("timeout", default: 120)
            configuration.maximumElapsedSeconds = try options.number("budget-seconds", default: 86_400)
            guard let safety = ProductionReplaySafety(rawValue: options.values["safety"] ?? (options.values["native"] != nil ? "inference" : "sideEffects")) else { throw ProductionFailure.invalid("Invalid replay safety.") }
            configuration.replaySafety = safety
            if options.values["max-cost"] != nil { configuration.maximumCost = try options.number("max-cost", default: 0); configuration.maximumCostPerAttempt = try options.number("cost-per-attempt", default: 0) }
            if options.values["targets"] != nil { configuration.targets = try ProductionCodec.decode([ProductionTarget].self, Data(contentsOf: options.url("targets"))) }
            if options.values["policy"] != nil { configuration.gate = try ProductionCodec.decode(ProductionGatePolicy.self, Data(contentsOf: options.url("policy"))) }
            if options.values["baseline"] != nil { configuration.baselineJobID = try options.uuid("baseline") }
            try printJSON(storage.createJob(name: options.required("name"), datasetRevision: options.required("dataset"), configuration: configuration))
        case "worker": try await work(options: options, storage: storage)
        case "report":
            let report = try storage.report(jobID: options.uuid("job"))
            if options.values["output"] != nil { try ProductionCodec.write(report, to: options.url("output")) }
            try printJSON(report); exit(Int32(report.exitCode))
        case "results": try printJSON(storage.records(jobID: options.uuid("job"), offset: options.integer("offset", default: 0), limit: options.integer("limit", default: 50)))
        case "pause", "resume", "cancel":
            let id = try options.uuid("job")
            try storage.setControl(jobID: id, paused: options.command == "cancel" ? nil : options.command == "pause",
                                   cancelled: options.command == "cancel" ? true : nil)
            try printJSON(storage.control(storage.loadJob(id)))
        case "review", "assign", "adjudicate", "reconcile":
            let id = try options.uuid("job"), slot = try options.integer("slot", default: -1), job = try storage.loadJob(id)
            let action: ProductionReviewAction = options.command == "assign" ? .assign : options.command == "adjudicate" ? .adjudicate : options.command == "reconcile" ? .reconcile : .label
            let response = try options.values["result"].map { _ in try ProductionCodec.decode(ProductionResponse.self, Data(contentsOf: options.url("result"))) }
            let outcome = options.values["verdict"].flatMap(ProductionOutcome.init(rawValue:))
            let event = ProductionReviewEvent(requestID: storage.requestID(job, slot: slot), reviewer: try options.required("reviewer"), action: action,
                assignee: options.values["assignee"], outcome: outcome, note: try options.required("note"), reconciledResponse: response)
            try storage.appendReview(jobID: id, slot: slot, event: event); try printJSON(storage.review(jobID: id, requestID: event.requestID))
        case "schedule":
            let schedule = ProductionSchedule(templateJobID: try options.uuid("job"), intervalSeconds: try options.number("interval", default: 3600),
                                              remainingRuns: try options.integer("runs", default: 1), paused: options.values["paused"] != nil)
            try storage.saveSchedule(schedule); try printJSON(schedule)
        case "tick": try printJSON(storage.tickSchedules())
        default: throw ProductionFailure.invalid(Options.help)
        }
    }
    static func work(options: Options, storage: ProductionStorage) async throws {
        let native = options.values["native"] != nil, identifier = try options.required("worker-id")
        var worker: ProductionWorker
        let execute: ProductionExecutor
        if native {
            worker = .init(id: identifier, name: identifier, platform: "macOS", operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                           hardware: hardware, locale: Locale.current.identifier, model: "Apple on-device")
            execute = nativeText
        } else if options.values["captured"] != nil {
            worker = .init(id: identifier, name: identifier, platform: "captured", operatingSystem: "imported evidence", hardware: "reported by source", locale: "source metadata", model: "original output")
            execute = ProductionStorage.capturedResponse
        } else {
            worker = try ProductionCodec.decode(ProductionWorker.self, Data(contentsOf: options.url("descriptor")))
            guard worker.id == identifier else { throw ProductionFailure.invalid("Descriptor worker ID does not match --worker-id.") }
            let executor = try ProductionCommandExecutor(executable: options.url("executor")); execute = executor.execute
        }
        var remaining = try options.integer("limit", default: Int.max)
        guard remaining > 0 else { throw ProductionFailure.invalid("--limit must be positive.") }
        repeat {
            _ = try storage.tickSchedules(); worker.lastSeen = Date(); try storage.register(worker)
            let jobs = try options.values["job"].map { _ in [try storage.loadJob(options.uuid("job"))] } ?? Array(storage.jobs().reversed())
            for job in jobs where remaining > 0 {
                let kind = (try? JSONSerialization.jsonObject(with: job.configuration.executionContext) as? [String: Any])?["kind"] as? String
                let expectedKind = native ? "foundation-models" : options.values["captured"] != nil ? "captured-output-review-v1" : "command"
                guard kind == expectedKind else { continue }
                if !native, expectedKind == "command" {
                    let context = try ProductionCodec.decode(ProductionCommandContext.self, job.configuration.executionContext)
                    guard context.executableDigest == (try ProductionCommandExecutor(executable: options.url("executor"))).executableDigest else { continue }
                }
                let count: Int
                do { count = try await ProductionBatchRunner(storage: storage).run(jobID: job.id, worker: worker, maximumResponses: remaining, execute: execute) }
                catch {
                    if options.values["job"] != nil { throw error }
                    FileHandle.standardError.write(Data(("\(job.id): \(error.localizedDescription)\n").utf8)); continue
                }
                remaining -= count
                if count > 0 { FileHandle.standardError.write(Data(("\(job.id): committed \(count) responses\n").utf8)) }
            }
            if options.values["poll"] == nil || remaining == 0 { break }
            try await Task.sleep(for: .seconds(2))
        } while !Task.isCancelled
    }
    static var hardware: String {
        #if arch(arm64)
        "Apple silicon"
        #else
        "Intel"
        #endif
    }
    static func nativeText(_ request: ProductionRequest) async throws -> ProductionResponse {
        #if canImport(FoundationModels)
        let settings = try ProductionCodec.decode(TextWorkerSettings.self, request.configuration.executionContext)
        guard settings.kind == "foundation-models", ["exact", "contains", "collect"].contains(settings.scoring) else {
            throw ProductionFailure.invalid("This worker supports the frozen text contract only; use the app or a trusted custom feature worker for richer setup.")
        }
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { throw ProductionFailure.unavailable("Apple's on-device model is unavailable on this worker.") }
        if settings.scoring != "collect", request.example.expected?.isEmpty != false { throw ProductionFailure.invalid("Scored text examples need a verified expected answer.") }
        let started = Date()
        let session = LanguageModelSession(model: model, instructions: settings.instructions)
        let response = try await session.respond(to: request.example.prompt).content
        let outcome: ProductionOutcome
        if settings.scoring == "collect" { outcome = .unscored }
        else {
            guard let expected = request.example.expected, !expected.isEmpty else { throw ProductionFailure.invalid("Scored text examples need a verified expected answer.") }
            let pass = settings.scoring == "exact" ? response.trimmingCharacters(in: .whitespacesAndNewlines) == expected.trimmingCharacters(in: .whitespacesAndNewlines)
                : response.range(of: expected, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            outcome = pass ? .passed : .failed
        }
        return .init(requestID: request.requestID, outcome: outcome, output: response,
                     latencyMilliseconds: Date().timeIntervalSince(started)*1000, cost: 0)
        #else
        throw ProductionFailure.unavailable("Native Apple execution requires an eligible macOS worker.")
        #endif
    }
}
