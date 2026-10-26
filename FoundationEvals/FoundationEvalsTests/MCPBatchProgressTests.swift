import Foundation
import Testing
@testable import FoundationEvals

/// Checks explicit lightweight polling omits qualification data while the default response retains the full audit.
@MainActor struct MCPBatchProgressTests {
    @Test func lightweightProgressIsExplicitAndFullAuditRemainsTheDefault() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-progress-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let control = EvaluationAppControl(store: EvaluationStore(supportDirectory: root))
        let storage = try #require(control.production.storage)
        let input = root.appendingPathComponent("input.jsonl")
        try Data("{\"id\":\"case\",\"prompt\":\"hello\",\"capturedOutput\":\"saved\"}\n".utf8).write(to: input)
        let dataset = try storage.importDataset(from: input, name: "Polling", version: "1")
        let job = try storage.createCapturedJob(name: "Polling", datasetRevision: dataset.revision)
        /// Invokes the production read through the public action gateway and requires a successful structured response.
        func read(_ fields: [String: MCPJSONValue]) async throws -> [String: MCPJSONValue] {
            let call = try MCPToolCatalog.parse(name: "eval_read_action", arguments: .object([
                "action": .string("eval_production_job_get"), "arguments": .object(fields)]))
            let payload = await MCPStoreAuthority.make(store: control.store, control: control).call(call)
            #expect(!payload.isError)
            return try #require(payload.structuredContent.objectValue)
        }
        let light = try await read(["jobID": .string(job.id.uuidString), "includeReport": .bool(false)])
        #expect(light["report"] == .null)
        #expect(light["progress"]?.objectValue?["completed"] == .integer(0))
        #expect(light["progress"]?.objectValue?["counts"] == nil)
        let full = try await read(["jobID": .string(job.id.uuidString)])
        #expect(full["report"]?.objectValue?["completed"] == .integer(0))
        #expect(full["progress"] == .null)
    }
}
