import Foundation
import Testing

@testable import FoundationEvals

struct MCPProductionEncodingTests {
  private static let snapshotOversizeMessage =
    "Response exceeds 4 MiB. Reduce page size or read the evidence export in chunks."
  private static let storageOversizeMessage =
    "Response exceeds 4 MiB. Reduce page size or use chunked exports."

  private struct CapturedPayload: Encodable, Sendable {
    let capturedAt: Date
    let output: String
    let artifact: Data
    let tokens: UInt64
  }

  /// Preserves production date rounding and payload values on main and detached actor paths.
  @Test(arguments: [1234.5676, -0.0016])
  func productionJSONMatchesCodecAcrossActors(seconds: Double) async throws {
    let payload = CapturedPayload(
      capturedAt: Date(timeIntervalSince1970: seconds), output: "Captured / output\n\"é\"",
      artifact: Data([0, 1, 255]), tokens: .max)
    let expected = MCPJSONValue.object([
      "capturedAt": .integer(seconds > 0 ? 1_234_568 : -2),
      "output": .string(payload.output), "artifact": .string("AAH/"),
      "tokens": .unsigned(.max),
    ])
    let codecValue = try JSONDecoder().decode(
      MCPJSONValue.self, from: ProductionCodec.encode(payload))
    let mainActorValue = try await MainActor.run {
      try MCPProductionControl.json(payload, oversizeMessage: Self.snapshotOversizeMessage)
    }
    let detachedValue = try await Task.detached {
      try MCPProductionControl.json(payload)
    }.value
    #expect(codecValue == expected)
    #expect(mainActorValue == expected)
    #expect(detachedValue == expected)
  }

  /// Allows exactly 4 MiB of encoded UTF-8 and preserves each caller's error for a one-byte overflow.
  @Test(arguments: [false, true])
  func productionJSONEnforcesByteLimitWithBothCallerMessages(snapshot: Bool) throws {
    let maximumBytes = 4_194_304
    let exact = String(repeating: "é", count: (maximumBytes - 2) / 2)
    let encode: (String) throws -> MCPJSONValue = snapshot
      ? { try MCPProductionControl.json($0, oversizeMessage: Self.snapshotOversizeMessage) }
      : { try MCPProductionControl.json($0) }
    #expect(exact.count < maximumBytes)
    #expect(try ProductionCodec.encode(exact).count == maximumBytes)
    #expect(try encode(exact) == .string(exact))

    let overflow = exact + "x"
    #expect(try ProductionCodec.encode(overflow).count == maximumBytes + 1)
    do {
      _ = try encode(overflow)
      Issue.record("A response one byte over 4 MiB was accepted.")
    } catch ProductionFailure.invalid(let message) {
      #expect(message == (snapshot ? Self.snapshotOversizeMessage : Self.storageOversizeMessage))
    }
  }

  /// Retains the production codec's date-range error instead of replacing it with size guidance.
  @Test(arguments: [Double.infinity, Double.nan, Double.greatestFiniteMagnitude])
  func productionJSONPreservesDateOverflowErrors(seconds: Double) throws {
    do {
      _ = try MCPProductionControl.json(Date(timeIntervalSince1970: seconds))
      Issue.record("An unrepresentable Unix millisecond timestamp was accepted.")
    } catch ProductionFailure.invalid(let message) {
      #expect(message == "Date exceeds the representable Unix millisecond range.")
    }
  }

  /// Both storage summaries redact only execution bytes while explicit context reads retain them.
  @MainActor @Test
  func storagePayloadsRedactContextWithoutChangingFrozenEvidence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mcp-production-encoding-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let control = EvaluationAppControl(store: EvaluationStore(supportDirectory: root))
    let storage = try #require(control.production.storage)
    let source = root.appendingPathComponent("source.jsonl")
    var bytes = try ProductionCodec.encode(
      ProductionExample(id: "captured", prompt: "Input", capturedOutput: "Original output"))
    bytes.append(10)
    try bytes.write(to: source)
    let dataset = try storage.importDataset(from: source, name: "Encoding fixture", version: "1")
    let context = Data(#"{"fixture":"frozen execution context"}"#.utf8)
    let configuration = ProductionJobConfiguration(
      scoringRevision: ProductionCodec.digest(Data("score".utf8)),
      executionRevision: ProductionCodec.digest(context), executionContext: context)
    let created = try storage.createJob(
      name: "Frozen job", datasetRevision: dataset.revision, configuration: configuration)
    // Compare canonical stored dates after the production codec's millisecond rounding.
    let job = try storage.loadJob(created.id)
    let redacted = await Task.detached { MCPProductionControl.stripped(job) }.value
    var expectedJob = job
    expectedJob.configuration.executionContext = Data()
    #expect(redacted == expectedJob)
    #expect(job.configuration.executionContext == context)
    let expectedValue = try JSONDecoder().decode(
      MCPJSONValue.self, from: ProductionCodec.encode(expectedJob))

    let state = try await MCPProductionControl.execute(
      .init(name: "eval_production_state", arguments: .object([:])), control: control)
    let fields: MCPJSONValue = .object(["jobID": .string(job.id.uuidString)])
    let detail = try await MCPProductionControl.execute(
      .init(name: "eval_production_job_get", arguments: fields), control: control)
    let contextRead = try await MCPProductionControl.execute(
      .init(name: "eval_production_context_read", arguments: fields), control: control)
    #expect(state.structuredContent.objectValue?["jobs"] == .array([expectedValue]))
    #expect(detail.structuredContent.objectValue?["job"] == expectedValue)
    #expect(detail.structuredContent.objectValue?["report"]?.objectValue?["job"] == expectedValue)
    #expect(detail.structuredContent.objectValue?["contextBytes"] == .integer(Int64(context.count)))
    #expect(contextRead.structuredContent.objectValue?["dataBase64"] == .string(context.base64EncodedString()))
    #expect(try storage.loadJob(job.id) == job)
    await control.production.closeAndWait()
  }
}
