import CoreGraphics
import Foundation
import FoundationModels
import Vision
import ImageIO
import Testing
@testable import FoundationEvals

struct ImageToolTests {
    @Test func imagePromptAdmissionCountsTextWithoutCallingImageTokenizer() async throws {
        let imageEstimate = try await EvaluationInputTokenCounter.promptEstimate(
            text: "Describe the image",
            prompt: Prompt { "Describe the image" },
            hasImages: true,
            using: PromptTokenRouteCounter(textCount: 17)
        )
        #expect(imageEstimate.count == 17)
        #expect(!imageEstimate.imageTokenCountAvailable)

        let textEstimate = try await EvaluationInputTokenCounter.promptEstimate(
            text: "Describe the text",
            prompt: Prompt { "Describe the text" },
            hasImages: false,
            using: PromptTokenRouteCounter(promptCount: 23)
        )
        #expect(textEstimate.count == 23)
        #expect(textEstimate.imageTokenCountAvailable)
    }

    @Test func historyTokenProjectionRemovesOnlyImageSegments() throws {
        let image = try #require(
            CGContext(
                data: nil,
                width: 2,
                height: 3,
                bitsPerComponent: 8,
                bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        )
        let text = Transcript.Segment.text(Transcript.TextSegment(id: "text", content: "keep me"))
        let attachment = Transcript.Segment.attachment(Transcript.AttachmentSegment(
            id: "image",
            content: .image(Transcript.ImageAttachment(image)),
            label: "scan"
        ))
        let history: [Transcript.Entry] = [
            .prompt(Transcript.Prompt(id: "prompt", segments: [text, attachment])),
            .toolOutput(Transcript.ToolOutput(
                id: "tool",
                toolName: "inspect",
                segments: [attachment, text]
            )),
            .response(Transcript.Response(id: "response", metadata: ["role": "answer"], segments: [text]))
        ]

        #expect(EvaluationInputTokenCounter.historyContainsImage(history))
        let projected = EvaluationInputTokenCounter.historyWithoutImages(history)
        #expect(!EvaluationInputTokenCounter.historyContainsImage(projected))
        #expect(projected.count == history.count)

        guard case .prompt(let prompt) = projected[0] else {
            Issue.record("Expected the projected prompt entry.")
            return
        }
        #expect(prompt.id == "prompt")
        #expect(prompt.segments == [text])

        guard case .toolOutput(let output) = projected[1] else {
            Issue.record("Expected the projected tool output entry.")
            return
        }
        #expect(output.id == "tool")
        #expect(output.toolName == "inspect")
        #expect(output.segments == [text])

        guard case .response(let response) = projected[2] else {
            Issue.record("Expected the projected response entry.")
            return
        }
        #expect(response.id == "response")
        #expect(response.segments == [text])
        #expect(response.metadata["role"]?.jsonString == "\"answer\"")

        let textOnlyHistory = [Transcript.Entry.prompt(
            Transcript.Prompt(id: "text-only", segments: [text])
        )]
        #expect(EvaluationInputTokenCounter.historyWithoutImages(textOnlyHistory) == textOnlyHistory)
    }

    @Test func imageReferenceResolvesOnlyFromTranscriptAndEmitsSafeMetadata() throws {
        let image = try #require(
            CGContext(
                data: nil,
                width: 2,
                height: 3,
                bitsPerComponent: 8,
                bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        )
        let history: [Transcript.Entry] = [
            .prompt(
                Transcript.Prompt(
                    segments: [
                        .attachment(
                            Transcript.AttachmentSegment(
                                content: .image(Transcript.ImageAttachment(image)),
                                label: "receipt"
                            )
                        )
                    ]
                )
            )
        ]
        let reference = try ImageReference(
            GeneratedContent(properties: ["attachmentLabel": "receipt"])
        )
        let arguments = GeneratedContent(
            properties: [
                "payload": GeneratedContent(properties: ["photo": reference])
            ]
        )
        let definition = EvaluationSchemaField(
            name: "ImagePayload",
            type: .object,
            children: [EvaluationSchemaField(name: "photo", type: .imageReference)]
        )
        let fields = [
            EvaluationSchemaField(
                name: "payload",
                type: .reference,
                referenceName: "ImagePayload"
            )
        ]

        let resolvedJSON = try EvaluationCustomTool.resolvedArgumentsJSON(
            argumentsJSON: arguments.jsonString,
            fields: fields,
            definitions: [definition],
            history: history
        )
        let requestBody = try EvaluationCustomTool.requestBody(
            toolName: "inspect_image",
            argumentsJSON: resolvedJSON
        )
        let envelope = try #require(
            JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        )
        let root = try #require(envelope["arguments"] as? [String: Any])
        let payload = try #require(root["payload"] as? [String: Any])
        let photo = try #require(payload["photo"] as? [String: Any])

        #expect(envelope["toolName"] as? String == "inspect_image")
        #expect(photo["kind"] as? String == "imageReference")
        #expect(photo["attachmentLabel"] as? String == "receipt")
        #expect(photo["width"] as? Int == 2)
        #expect(photo["height"] as? Int == 3)
        #expect(photo["orientation"] as? Int != nil)
        #expect(photo["url"] == nil)
        #expect(photo["path"] == nil)
    }

    @Test func imageReferenceOutsideTranscriptIsRejected() throws {
        let reference = try ImageReference(
            GeneratedContent(properties: ["attachmentLabel": "missing-image"])
        )
        let arguments = GeneratedContent(properties: ["image": reference])

        do {
            _ = try EvaluationCustomTool.resolvedArgumentsJSON(
                argumentsJSON: arguments.jsonString,
                fields: [EvaluationSchemaField(name: "image", type: .imageReference)],
                definitions: [],
                history: [Transcript.Entry]()
            )
            Issue.record("Expected an image outside the session transcript to be rejected.")
        } catch let error as EvaluationCustomToolError {
            guard case .imageReferenceNotFound(let label) = error else {
                Issue.record("Unexpected image reference error: \(error)")
                return
            }
            #expect(label == "missing-image")
        }
    }

    @Test func visionToolConfigurationUsesActualAppleToolsAndRoundTrips() throws {
        let configuration = EvaluationVisionToolConfiguration(
            ocrEnabled: true,
            barcodeEnabled: true
        )
        let toolNames = configuration.makeTools().map { $0.name }
        let tools = configuration.makeTools()

        #expect(toolNames == configuration.enabledToolNames)
        #expect(Set(toolNames) == EvaluationVisionToolConfiguration.knownToolNames)
        #expect(tools[0] is OCRTool)
        #expect(tools[1] is BarcodeReaderTool)
        #expect(!configuration.isEmpty)

        let decoded = try JSONDecoder().decode(
            EvaluationVisionToolConfiguration.self,
            from: JSONEncoder().encode(configuration)
        )
        #expect(decoded == configuration)
        #expect(EvaluationVisionToolConfiguration().makeTools().isEmpty)
    }

    @Test func boundedToolSharesCallLimitAndRejectsOversizedOutput() async throws {
        let sharedLimiter = EvaluationToolCallLimiter(maximumCalls: 1)
        let first = EvaluationBoundedTool(
            tool: StubImageTool(name: "first_image_tool", output: "first"),
            limiter: sharedLimiter,
            tokenCounter: FixedToolOutputTokenCounter(count: 1)
        )
        let second = EvaluationBoundedTool(
            tool: StubImageTool(name: "second_image_tool", output: "second"),
            limiter: sharedLimiter,
            tokenCounter: FixedToolOutputTokenCounter(count: 1)
        )
        let arguments = StubImageTool.Arguments(value: "image")

        _ = try await first.call(arguments: arguments)
        do {
            _ = try await second.call(arguments: arguments)
            Issue.record("Expected the shared built-in tool limit to reject the second call.")
        } catch let error as EvaluationBoundedToolError {
            guard case .callLimitReached(maximum: 1) = error else {
                Issue.record("Unexpected built-in tool error: \(error)")
                return
            }
        }

        let outputLimited = EvaluationBoundedTool(
            tool: StubImageTool(name: "large_image_tool", output: "large"),
            limiter: EvaluationToolCallLimiter(maximumCalls: 1),
            tokenCounter: FixedToolOutputTokenCounter(
                count: EvaluationCustomTool.maximumOutputTokens + 1
            )
        )
        do {
            _ = try await outputLimited.call(arguments: arguments)
            Issue.record("Expected an oversized built-in tool output to be rejected.")
        } catch let error as EvaluationBoundedToolError {
            guard case .outputTokenLimitExceeded(let actual, let maximum) = error else {
                Issue.record("Unexpected built-in tool error: \(error)")
                return
            }
            #expect(actual == EvaluationCustomTool.maximumOutputTokens + 1)
            #expect(maximum == EvaluationCustomTool.maximumOutputTokens)
        }
    }

    @Test func nativeImageToolBoundaryEnforcesCallsAndOutputWithoutWrappingTools() async throws {
        let toolName = OCRTool().name
        let call = Transcript.ToolCall(
            id: "ocr-call",
            toolName: toolName,
            arguments: GeneratedContent(properties: ["image": "file-1"])
        )
        let output = Transcript.ToolOutput(
            id: call.id,
            toolName: toolName,
            segments: [.text(Transcript.TextSegment(content: "VISION-731"))]
        )
        let boundary = EvaluationBuiltinToolBoundary(
            toolNames: [toolName],
            limiter: EvaluationToolCallLimiter(maximumCalls: 1),
            tokenCounter: FixedToolOutputTokenCounter(count: 1)
        )

        try await boundary.validateToolCall(call)
        try await boundary.validateToolOutput(call: call, output: output)
        do {
            try await boundary.validateToolCall(call)
            Issue.record("Expected the image tool call boundary to reject the second call.")
        } catch let error as EvaluationBoundedToolError {
            guard case .callLimitReached(maximum: 1) = error else {
                Issue.record("Unexpected image tool call error: \(error)")
                return
            }
        }

        let outputLimited = EvaluationBuiltinToolBoundary(
            toolNames: [toolName],
            limiter: EvaluationToolCallLimiter(maximumCalls: 1),
            tokenCounter: FixedToolOutputTokenCounter(
                count: EvaluationCustomTool.maximumOutputTokens + 1
            )
        )
        do {
            try await outputLimited.validateToolOutput(call: call, output: output)
            Issue.record("Expected the image tool output boundary to reject oversized output.")
        } catch let error as EvaluationBoundedToolError {
            guard case .outputTokenLimitExceeded(let actual, let maximum) = error else {
                Issue.record("Unexpected image tool output error: \(error)")
                return
            }
            #expect(actual == EvaluationCustomTool.maximumOutputTokens + 1)
            #expect(maximum == EvaluationCustomTool.maximumOutputTokens)
        }
    }

    @Test func nativeImageToolOutputProjectionUsesCountablePromptContent() async throws {
        let output = Transcript.ToolOutput(
            id: "ocr-call",
            toolName: OCRTool().name,
            segments: [
                .text(Transcript.TextSegment(content: "VISION-731")),
                .structure(Transcript.StructuredSegment(
                    schemaName: "OCRMetadata",
                    content: GeneratedContent(properties: ["language": "en"])
                ))
            ]
        )

        let promptSegments = try EvaluationBuiltinToolBoundary.promptSegments(for: output)
        let tokenCount = try await EvaluationSystemPromptTokenCounter().tokenCount(
            for: promptSegments
        )

        #expect(promptSegments.count == output.segments.count)
        #expect(tokenCount > 0)
    }

    @Test func visionTraceExtractionKeepsCallsAndOutputsWithoutInventingTiming() throws {
        let ocrName = try #require(
            EvaluationVisionToolConfiguration(ocrEnabled: true).enabledToolNames.first
        )
        let arguments = GeneratedContent(
            properties: ["image": GeneratedContent(properties: ["attachmentLabel": "scan"])]
        )
        let entries: [Transcript.Entry] = [
            .toolCalls(
                Transcript.ToolCalls([
                    Transcript.ToolCall(id: "vision-call", toolName: ocrName, arguments: arguments),
                    Transcript.ToolCall(
                        id: "other-call",
                        toolName: "unrelated_tool",
                        arguments: GeneratedContent(properties: ["value": "ignored"])
                    )
                ])
            ),
            .toolOutput(
                Transcript.ToolOutput(
                    id: "vision-call",
                    toolName: ocrName,
                    segments: [.text(Transcript.TextSegment(content: "Invoice total: 42"))]
                )
            )
        ]

        let traces = EvaluationBuiltinToolTrace.visionTools(from: entries)

        #expect(traces.count == 1)
        #expect(traces[0].id == "vision-call")
        #expect(traces[0].toolName == ocrName)
        #expect(traces[0].argumentsJSON.contains("scan"))
        #expect(traces[0].output == "Invoice total: 42")
    }
}

private enum PromptTokenRouteError: Error {
    case unexpectedPromptCount
    case unexpectedTextCount
}

private struct PromptTokenRouteCounter: EvaluationPromptInputTokenCounting {
    var textCount: Int?
    var promptCount: Int?

    init(textCount: Int? = nil, promptCount: Int? = nil) {
        self.textCount = textCount
        self.promptCount = promptCount
    }

    func tokenCount(for prompt: Prompt) async throws -> Int {
        guard let promptCount else { throw PromptTokenRouteError.unexpectedPromptCount }
        return promptCount
    }

    func tokenCount(forText text: String) async throws -> Int {
        guard let textCount else { throw PromptTokenRouteError.unexpectedTextCount }
        return textCount
    }
}

private struct StubImageTool: Tool {
    let name: String
    let description = "Returns deterministic image metadata."
    let output: String

    @Generable
    struct Arguments {
        var value: String
    }

    func call(arguments: Arguments) async throws -> String {
        output
    }
}

private struct FixedToolOutputTokenCounter: EvaluationToolOutputTokenCounting {
    var count: Int

    func tokenCount<Output: PromptRepresentable>(for output: Output) async throws -> Int {
        count
    }
}
