import CoreGraphics
import Foundation
import FoundationModels
import Testing
@testable import FoundationEvals

struct EvaluationSchemaBoundaryTests {
    @Test(arguments: [false, true])
    func completedStructuredResponsesEnforceTheConfiguredSchema(streaming: Bool) async throws {
        var suite = EvaluationSuite()
        suite.features.streamResponse = streaming
        suite.features.outputFields = [.init(name: "count", type: .integer,
            constraints: .init(integerMinimum: 1, integerMaximum: 3))]
        for (json, valid) in [(#"{"count":1}"#, true), (#"{"count":3}"#, true),
                              (#"{}"#, false), (#"{"count":"wrong"}"#, false),
                              (#"{"count":true}"#, false), (#"{"count":1.5}"#, false),
                              (#"{"count":0}"#, false), (#"{"count":4}"#, false),
                              (#"{"count":1,"unexpected":true}"#, false), (#"[]"#, false)] {
            let session = LanguageModelSession(model: SchemaBoundaryModel(executorConfiguration: .response(json)))
            do {
                let response = try await EvaluationFeatureResponse.generate(session: session,
                    prompt: Prompt("Return count."), suite: suite, metadata: [:])
                #expect(valid, "Accepted schema violation: \(json)")
                #expect(!response.content.isEmpty)
            } catch let error as EvaluationSchemaValidationError {
                #expect(!valid, "Rejected valid boundary: \(json)")
                #expect(error.localizedDescription.contains("Schema violation at $"))
            }
        }
    }

    @Test(arguments: [false, true])
    func optionalNilRepresentationAndPatternMatchingFollowTheSchema(streaming: Bool) async throws {
        for explicitNil in [false, true] {
            var suite = EvaluationSuite()
            suite.features.streamResponse = streaming
            suite.features.outputRepresentNilExplicitlyInGeneratedContent = explicitNil
            suite.features.outputFields = [
                .init(name: "required", type: .string, constraints: .init(stringPattern: "[A-Z]{2}")),
                .init(name: "optional", type: .string, isOptional: true)
            ]
            let omitted = #"{"required":"xABx"}"#
            let null = #"{"required":"xABx","optional":null}"#
            let cases = [(omitted, !explicitNil), (null, explicitNil),
                         (#"{"required":"AB","optional":"value"}"#, true),
                         (#"{"required":null,"optional":"value"}"#, false)]
            for (json, valid) in cases {
                let session = LanguageModelSession(model: SchemaBoundaryModel(executorConfiguration: .response(json)))
                do {
                    _ = try await EvaluationFeatureResponse.generate(session: session,
                        prompt: Prompt("Return the configured fields."), suite: suite, metadata: [:])
                    #expect(valid, "Accepted invalid nil representation: \(json)")
                } catch let error as EvaluationSchemaValidationError {
                    #expect(!valid, "Rejected valid nil representation: \(error)")
                }
            }
        }
        let nullable = EvaluationSchemaField(name: "value", type: .union,
            children: [.init(name: "empty", type: .null), .init(name: "text", type: .string)])
        try EvaluationSchemaValidator.validate(GeneratedContent(json: #"{"value":null}"#), fields: [nullable])
        #expect(throws: EvaluationSchemaValidationError.self) {
            try EvaluationSchemaValidator.validate(GeneratedContent(json: "{}"), fields: [nullable])
        }
        let anchored = EvaluationSchemaField(name: "value", type: .string,
            constraints: .init(stringPattern: "^[A-Z]{2}$"))
        #expect(throws: EvaluationSchemaValidationError.self) {
            try EvaluationSchemaValidator.validate(GeneratedContent(json: #"{"value":"xABx"}"#), fields: [anchored])
        }
    }

    @Test func partialStructuredSnapshotsAreNotValidatedBeforeCompletion() async throws {
        var suite = EvaluationSuite()
        suite.features.streamResponse = true
        suite.features.outputFields = [.init(name: "count", type: .integer)]
        let session = LanguageModelSession(model: SchemaBoundaryModel(executorConfiguration: .splitResponse))
        let response = try await EvaluationFeatureResponse.generate(session: session,
            prompt: Prompt("Return count."), suite: suite, metadata: [:])
        #expect(try GeneratedContent(json: response.content).value(Int.self, forProperty: "count") == 1)
    }

    @Test(arguments: [EvaluationCustomToolMode.fixture, .localHTTP])
    func toolArgumentsAreValidatedBeforeDispatch(mode: EvaluationCustomToolMode) async throws {
        for (json, valid) in [(#"{"count":1}"#, true), (#"{"count":3}"#, true),
                              (#"{}"#, false), (#"{"count":"wrong"}"#, false),
                              (#"{"count":0}"#, false), (#"{"count":4}"#, false),
                              (#"{"count":1,"unexpected":true}"#, false)] {
            let recorder = EvaluationCustomToolRecorder(maximumCalls: 1)
            let transport = SchemaBoundaryHTTPClient()
            let definition = EvaluationCustomToolDefinition(name: "requires_count", description: "Needs a bounded count.",
                parameters: [.init(name: "count", type: .integer,
                    constraints: .init(integerMinimum: 1, integerMaximum: 3))], mode: mode,
                fixtureResponse: "accepted", endpoint: "http://127.0.0.1:19090/tool")
            let tool = try EvaluationCustomTool(definition: definition, recorder: recorder,
                httpClient: transport, tokenCounter: SchemaBoundaryTokenCounter())
            let session = LanguageModelSession(model: SchemaBoundaryModel(executorConfiguration: .tool(json)), tools: [tool])
            do {
                _ = try await session.respond(to: Prompt("Call requires_count."),
                    options: .init(maximumResponseTokens: 128, toolCallingMode: .allowed))
                #expect(valid, "The invalid tool call completed: \(json)")
            } catch { #expect(!valid, "The valid tool call failed: \(error)") }
            let traces = await recorder.snapshot()
            let trace = try #require(traces.first)
            #expect(traces.count == 1)
            #expect(trace.outcome == (valid ? .succeeded : .rejected))
            #expect(await transport.calls == (valid && mode == .localHTTP ? 1 : 0))
            if !valid {
                #expect(trace.output == nil)
                let path = json.contains("unexpected") ? "$.unexpected" : "$.count"
                #expect(trace.errorDescription?.contains("Schema violation at \(path)") == true)
            }
        }
    }

    @Test(arguments: [false, true])
    func unconfiguredNestedAndImagePropertiesNeverCompleteOrDispatch(streaming: Bool) async throws {
        let cases: [(EvaluationSchemaField, String, String)] = [
            (.init(name: "payload", type: .object, children: [.init(name: "count", type: .integer)]),
             #"{"payload":{"count":1,"unexpected":true}}"#, "$.payload.unexpected"),
            (.init(name: "image", type: .imageReference),
             #"{"image":{"attachmentLabel":"file-1","unexpected":true}}"#, "$.image.unexpected")
        ]
        for (field, json, path) in cases {
            var suite = EvaluationSuite()
            suite.features.streamResponse = streaming
            suite.features.outputFields = [field]
            let responseSession = LanguageModelSession(model: SchemaBoundaryModel(executorConfiguration: .response(json)))
            do {
                _ = try await EvaluationFeatureResponse.generate(session: responseSession,
                    prompt: Prompt("Return the configured object."), suite: suite, metadata: [:])
                Issue.record("Completed output contained an unconfigured property: \(path)")
            } catch let error as EvaluationSchemaValidationError { #expect(error.path == path) }

            let recorder = EvaluationCustomToolRecorder(maximumCalls: 1)
            let transport = SchemaBoundaryHTTPClient()
            let definition = EvaluationCustomToolDefinition(name: "requires_count", description: "Uses configured object fields.",
                parameters: [field], mode: .localHTTP, endpoint: "http://127.0.0.1:19090/tool")
            let tool = try EvaluationCustomTool(definition: definition, recorder: recorder,
                httpClient: transport, tokenCounter: SchemaBoundaryTokenCounter())
            let toolSession = LanguageModelSession(model: SchemaBoundaryModel(executorConfiguration: .tool(json)), tools: [tool])
            do {
                _ = try await toolSession.respond(to: Prompt("Call requires_count."),
                    options: .init(maximumResponseTokens: 128, toolCallingMode: .allowed))
                Issue.record("Tool arguments contained an unconfigured property: \(path)")
            } catch { }
            #expect(await transport.calls == 0)
            let trace = try #require(await recorder.snapshot().first)
            #expect(trace.outcome == .rejected)
            #expect(trace.errorDescription?.contains("Schema violation at \(path)") == true)
        }
    }

    @Test func validNestedOptionalToolArgumentsRetainTheirValuesThroughDispatch() async throws {
        let frozenDefinition = EvaluationCustomToolDefinition(name: "requires_count", description: "Checks nested values.",
            parameters: [.init(name: "payload", type: .object, children: [
                .init(name: "note", type: .string, isOptional: true),
                .init(name: "items", type: .array, children: [.init(name: "item", type: .reference, referenceName: "Rank")],
                    constraints: .init(arrayMinimumCount: 1, arrayMaximumCount: 2))])],
            schemaDefinitions: [.init(name: "Rank", type: .integer, constraints: .init(integerMinimum: 0, integerMaximum: 2))],
            mode: .localHTTP, endpoint: "http://127.0.0.1:19090/tool")
        for explicitNil in [false, true] {
            var definition = frozenDefinition
            definition.parameters.append(.init(name: "contextNote", type: .string, isOptional: true))
            definition.representNilExplicitlyInGeneratedContent = explicitNil
            definition.parameters[0].representNilExplicitlyInGeneratedContent = explicitNil
            let json = explicitNil
                ? #"{"payload":{"note":null,"items":[2,0]},"contextNote":null}"#
                : #"{"payload":{"items":[0]}}"#
            let recorder = EvaluationCustomToolRecorder(maximumCalls: 1)
            let transport = SchemaBoundaryHTTPClient()
            let tool = try EvaluationCustomTool(definition: definition, recorder: recorder,
                httpClient: transport, tokenCounter: SchemaBoundaryTokenCounter())
            let session = LanguageModelSession(model: SchemaBoundaryModel(executorConfiguration: .tool(json)), tools: [tool])
            _ = try await session.respond(to: Prompt("Call requires_count."),
                options: .init(maximumResponseTokens: 128, toolCallingMode: .allowed))
            let body = try #require(await transport.bodies.first)
            let envelope = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let sent = try JSONSerialization.data(withJSONObject: #require(envelope["arguments"]), options: [.sortedKeys])
            let expected = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: Data(json.utf8)), options: [.sortedKeys])
            #expect(sent == expected)
            #expect(await recorder.snapshot().first?.outcome == .succeeded)
        }
    }

    /// Verifies non-image union alternatives retain their values through schema validation, image resolution, and HTTP dispatch.
    @Test func nonImageUnionAlternativesRetainTheirValuesThroughDispatch() async throws {
        let cases: [(EvaluationSchemaField, String)] = [
            (.init(name: "payload", type: .union, children: [
                .init(name: "images", type: .array, children: [.init(name: "item", type: .imageReference)]),
                .init(name: "messages", type: .array, children: [.init(name: "item", type: .string)])
            ]), #"{"payload":["hello"]}"#),
            (.init(name: "payload", type: .union, children: [
                .init(name: "image", type: .object, children: [
                    .init(name: "kind", type: .enumeration, enumValues: [.init(value: "image")]),
                    .init(name: "value", type: .imageReference)
                ]),
                .init(name: "message", type: .object, children: [
                    .init(name: "kind", type: .enumeration, enumValues: [.init(value: "text")]),
                    .init(name: "value", type: .string)
                ])
            ]), #"{"payload":{"kind":"text","value":"hello"}}"#),
            (.init(name: "payload", type: .union, children: [
                .init(name: "image", type: .imageReference),
                .init(name: "message", type: .object, children: [
                    .init(name: "attachmentLabel", type: .string), .init(name: "note", type: .string)
                ])
            ]), #"{"payload":{"attachmentLabel":"receipt","note":"keep"}}"#)
        ]
        for (field, json) in cases {
            let recorder = EvaluationCustomToolRecorder(maximumCalls: 1)
            let transport = SchemaBoundaryHTTPClient()
            let definition = EvaluationCustomToolDefinition(name: "requires_count", description: "Checks union values.",
                parameters: [field], mode: .localHTTP, endpoint: "http://127.0.0.1:19090/tool")
            let tool = try EvaluationCustomTool(definition: definition, recorder: recorder,
                httpClient: transport, tokenCounter: SchemaBoundaryTokenCounter())
            let session = LanguageModelSession(model: SchemaBoundaryModel(executorConfiguration: .tool(json)), tools: [tool])
            _ = try await session.respond(to: Prompt("Call requires_count."),
                options: .init(maximumResponseTokens: 128, toolCallingMode: .allowed))

            let body = try #require(await transport.bodies.first)
            let envelope = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let sent = try JSONSerialization.data(withJSONObject: #require(envelope["arguments"]), options: [.sortedKeys])
            let expected = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: Data(json.utf8)), options: [.sortedKeys])
            #expect(sent == expected)
            #expect(await transport.calls == 1)
            #expect(await recorder.snapshot().first?.outcome == .succeeded)
        }
    }

    /// Verifies image-object and image-array union alternatives resolve transcript metadata before the real custom-tool HTTP dispatch path.
    @Test(arguments: [false, true])
    func imageUnionAlternativesResolveBeforeHTTPDispatch(arrayPayload: Bool) async throws {
        let image = try #require(CGContext(data: nil, width: 2, height: 3, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let history: [Transcript.Entry] = [.prompt(Transcript.Prompt(segments: [
            .attachment(Transcript.AttachmentSegment(content: .image(Transcript.ImageAttachment(image)), label: "receipt"))
        ]))]
        let imageAlternative = EvaluationSchemaField(name: "image", type: arrayPayload ? .array : .object,
            children: [.init(name: arrayPayload ? "item" : "photo", type: .imageReference)])
        let textAlternative = EvaluationSchemaField(name: "message", type: arrayPayload ? .array : .object,
            children: [.init(name: arrayPayload ? "item" : "photo", type: .string)])
        let fields = [EvaluationSchemaField(name: "payload", type: .union,
            children: [textAlternative, imageAlternative])]
        let json = arrayPayload
            ? #"{"payload":[{"attachmentLabel":"receipt"}]}"#
            : #"{"payload":{"photo":{"attachmentLabel":"receipt"}}}"#
        let recorder = EvaluationCustomToolRecorder(maximumCalls: 1)
        let transport = SchemaBoundaryHTTPClient()
        let definition = EvaluationCustomToolDefinition(name: "requires_count", description: "Checks image union dispatch.",
            parameters: fields, mode: .localHTTP, endpoint: "http://127.0.0.1:19090/tool")
        let tool = try EvaluationCustomTool(definition: definition, recorder: recorder,
            httpClient: transport, tokenCounter: SchemaBoundaryTokenCounter())
        let session = EvaluationConversationRuntime.makeSession(
            model: SchemaBoundaryModel(executorConfiguration: .tool(json)), tools: [tool], instructions: "", history: history,
            modelHistoryProjection: nil)

        let response = try await session.respond(to: Prompt("Call requires_count."),
            options: .init(maximumResponseTokens: 128, toolCallingMode: .allowed))
        let body = try #require(await transport.bodies.first)
        let envelope = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let arguments = try #require(envelope["arguments"] as? [String: Any])
        let metadata: [String: Any]
        if arrayPayload {
            let payload = try #require(arguments["payload"] as? [[String: Any]])
            #expect(payload.count == 1)
            metadata = try #require(payload.first)
        } else {
            let payload = try #require(arguments["payload"] as? [String: Any])
            metadata = try #require(payload["photo"] as? [String: Any])
        }
        #expect(response.content == "Done")
        #expect(envelope["toolName"] as? String == "requires_count")
        #expect(metadata["kind"] as? String == "imageReference")
        #expect(metadata["attachmentLabel"] as? String == "receipt")
        #expect(metadata["width"] as? Int == 2)
        #expect(metadata["height"] as? Int == 3)
        #expect(metadata["orientation"] as? Int != nil)
        #expect(metadata["url"] == nil && metadata["path"] == nil)
        #expect(await transport.calls == 1)
        #expect(await recorder.snapshot().first?.outcome == .succeeded)
    }

    @Test func nestedDefinitionsAndOptionalValuesKeepTheirConfiguredSemantics() throws {
        let rank = EvaluationSchemaField(name: "Rank", type: .integer,
            constraints: .init(integerMinimum: 0, integerMaximum: 2))
        let fields: [EvaluationSchemaField] = [
            .init(name: "payload", type: .object, children: [
                .init(name: "count", type: .integer, constraints: .init(integerMinimum: 1, integerMaximum: 3)),
                .init(name: "ratio", type: .number, constraints: .init(numberMinimum: 0.5, numberMaximum: 2.5)),
                .init(name: "flag", type: .boolean),
                .init(name: "token", type: .string, constraints: .init(stringPattern: "[A-Z]{2}")),
                .init(name: "choice", type: .enumeration, enumValues: [.init(value: "red"), .init(value: "blue")]),
                .init(name: "note", type: .string, isOptional: true),
                .init(name: "items", type: .array, children: [.init(name: "item", type: .reference, referenceName: "Rank")],
                    constraints: .init(arrayMinimumCount: 1, arrayMaximumCount: 2)),
                .init(name: "result", type: .union, children: [.init(name: "none", type: .null),
                    .init(name: "message", type: .object, children: [.init(name: "text", type: .string)])])
            ]),
            .init(name: "sourceImage", type: .imageReference, isOptional: true)
        ]
        let json = #"{"payload":{"count":1,"ratio":0.5,"flag":true,"token":"AB","choice":"red","items":[0],"result":null}}"#
        try EvaluationSchemaValidator.validate(GeneratedContent(json: json), fields: fields, definitions: [rank])
        let upper = #"{"payload":{"count":3,"ratio":2.5,"flag":false,"token":"ZZ","choice":"blue","note":"ok","items":[2,0],"result":{"text":"ok"}},"sourceImage":{"attachmentLabel":"file-1"}}"#
        try EvaluationSchemaValidator.validate(GeneratedContent(json: upper), fields: fields, definitions: [rank])
        let invalid: [(String, Any)] = [("count", 1.5), ("ratio", 0.4), ("ratio", 2.6), ("flag", 1),
            ("token", "abc"), ("choice", "green"), ("note", 1), ("items", []), ("items", [0, 1, 2]),
            ("items", [3]), ("result", false), ("result", ["text": 1])]
        for (key, value) in invalid {
            var document = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            var payload = try #require(document["payload"] as? [String: Any])
            payload[key] = value; document["payload"] = payload
            let content = try GeneratedContent(json: String(decoding: JSONSerialization.data(withJSONObject: document), as: UTF8.self))
            #expect(throws: EvaluationSchemaValidationError.self) {
                try EvaluationSchemaValidator.validate(content, fields: fields, definitions: [rank])
            }
        }
    }
}

private struct SchemaBoundaryModel: LanguageModel {
    typealias Executor = SchemaBoundaryExecutor
    enum Configuration: Hashable, Sendable { case response(String), splitResponse, tool(String) }
    var executorConfiguration: Configuration
    var capabilities: LanguageModelCapabilities { .init([.guidedGeneration, .toolCalling, .vision]) }
}

private struct SchemaBoundaryExecutor: LanguageModelExecutor {
    typealias Model = SchemaBoundaryModel
    typealias Configuration = Model.Configuration
    let configuration: Configuration
    init(configuration: Configuration) throws { self.configuration = configuration }
    func prewarm(model: Model, transcript: Transcript) {}
    func respond(to request: LanguageModelExecutorGenerationRequest, model: Model,
                 streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        switch configuration {
        case .response(let json):
            await channel.send(.response(action: .appendText(json, tokenCount: 5)))
        case .splitResponse:
            await channel.send(.response(action: .appendText("{\"count\":", tokenCount: 3)))
            try await Task.sleep(for: .milliseconds(120))
            await channel.send(.response(action: .appendText("1}", tokenCount: 2)))
        case .tool(let json):
            if request.transcript.history.contains(where: { if case .toolOutput = $0 { true } else { false } }) {
                await channel.send(.response(action: .appendText("Done", tokenCount: 1)))
            } else {
                await channel.send(.toolCalls(action: .toolCall(id: "boundary-call", name: "requires_count",
                    action: .appendArguments(json, tokenCount: 2))))
            }
        }
    }
}

private struct SchemaBoundaryTokenCounter: EvaluationCustomToolTokenCounting {
    func tokenCount(for text: String) async throws -> Int { 1 }
}

private actor SchemaBoundaryHTTPClient: EvaluationCustomToolHTTPClient {
    private(set) var calls = 0
    private(set) var bodies: [Data] = []
    func post(body: Data, to endpoint: URL) async throws -> String {
        calls += 1; bodies.append(body); return "accepted"
    }
}
