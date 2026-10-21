import Foundation
import FoundationModels
import Testing
import UniformTypeIdentifiers
@testable import FoundationEvals

struct BuiltinToolTraceIntegrityTests {
    @Test(arguments: ["é", "🙂", "👩🏽‍💻"])
    func outputByteLimitDoesNotInventReplacementCharacters(character: String) throws {
        let limit = EvaluationCustomToolDefinition.maximumOutputBytes
        let prefix = String(repeating: "a", count: limit - 1)
        let output = prefix + character + "suffix"
        let entries = Self.entries(arguments: GeneratedContent(properties: [:]), output: output)
        let trace = try #require(EvaluationBuiltinToolTrace.tools(from: entries, names: ["builtin"]).first)
        let captured = try #require(trace.output)
        #expect(captured.utf8.count <= limit)
        #expect(captured == prefix)
        #expect(!captured.contains("\u{FFFD}"))

        let exact = String(repeating: "a", count: limit - character.utf8.count) + character
        let exactTrace = try #require(EvaluationBuiltinToolTrace.tools(
            from: Self.entries(arguments: GeneratedContent(properties: [:]), output: exact), names: ["builtin"]).first)
        #expect(exactTrace.output == exact)
    }

    @Test func argumentEvidenceRemainsAnExactBoundedUTF8Prefix() throws {
        let limit = EvaluationCustomToolDefinition.maximumArgumentBytes
        for padding in 0..<4 {
            let arguments = GeneratedContent(properties: [
                "value": String(repeating: "a", count: padding) + String(repeating: "🙂", count: limit / 4 + 1)
            ])
            let trace = try #require(EvaluationBuiltinToolTrace.tools(
                from: Self.entries(arguments: arguments, output: "ok"), names: ["builtin"]).first)
            #expect(trace.argumentsJSON.utf8.count <= limit)
            #expect(arguments.jsonString.utf8.starts(with: trace.argumentsJSON.utf8))
            #expect(!trace.argumentsJSON.contains("\u{FFFD}"))
        }
    }

    // Inspected SDK modules: 2.1.8 declares Entry.data; 2.0.68 does not.
    // Runtime availability alone cannot hide missing SDK declarations.
    #if canImport(FoundationModels, _version: 2.1.8)
    @Test func opaqueDataHistoryStaysUnscoredAndDoesNotInventToolOutput() throws {
        if #available(macOS 27.2, iOS 27.2, *) {
            let data = Transcript.Entry.data(.init(contentType: .data, content: Data([0xFF, 0x00, 0x80]),
                metadata: GeneratedContent(properties: ["providerMetadata": "opaque-metadata"])))
            let context = EvaluationJudgeSubjectContext.capture([data], instructions: "Instructions")
            #expect(context.entries.isEmpty)
            #expect(context.unavailableReason != nil)
            #expect(throws: EvaluationJudgeSubjectContext.ContextError.self) { try context.validated() }
            var entries = Self.entries(arguments: GeneratedContent(properties: [:]), output: "Observed tool output")
            entries.insert(data, at: 1)
            let trace = try #require(EvaluationBuiltinToolTrace.tools(from: entries, names: ["builtin"]).first)
            #expect(trace.output == "Observed tool output")
            #expect(trace.output?.contains("opaque-metadata") == false)
        }
    }
    #endif

    private static func entries(arguments: GeneratedContent, output: String) -> [Transcript.Entry] {
        [.toolCalls(Transcript.ToolCalls([.init(id: "call", toolName: "builtin", arguments: arguments)])),
         .toolOutput(.init(id: "call", toolName: "builtin", segments: [.text(.init(content: output))]))]
    }
}
