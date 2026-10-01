# Custom local provider protocol

Foundation Evals can run a developer-owned model implementation through its Foundation Models `LanguageModel` adapter. The adapter sends one HTTP request for each `LanguageModelExecutor` response turn and converts the returned event stream into Foundation Models response, reasoning, tool-call, and usage channel updates.

This page defines Foundation Evals protocol version 1. It is an app-specific loopback protocol, not an Apple API or a general model-provider standard.

## Transport and endpoint rules

The adapter makes an HTTP `POST` with these headers:

~~~http
Content-Type: application/json
Accept: application/x-ndjson
~~~

The request body is one JSON object. The response body is newline-delimited JSON (NDJSON), with one event object per line. A final event without a trailing newline is accepted. Empty lines and lines containing only ASCII spaces or tabs are ignored. Both LF and CRLF line endings work.

The configured URL must use literal `http://127.0.0.1:<port>/...`. Foundation Evals rejects HTTPS, hostnames such as `localhost`, IPv6 loopback, missing ports, credentials, query strings, fragments, and port `17873`, which is reserved for the app's MCP server. The URL is limited to 2,048 UTF-8 bytes.

The adapter uses an ephemeral URL session with redirects, proxies, cookies, credentials, and caches disabled. It accepts only a 2xx HTTP status. It does not retry a request. Initialization and `prewarm` do not contact the provider.

The configured request timeout must be from 0.1 through 60 seconds. The other transport limits are:

| Item | Limit |
|---|---:|
| Encoded request body | 8 MiB |
| Entire response body | 8 MiB |
| One buffered NDJSON event line | 1 MiB |
| Declared provider context size | 1 through 262,144 tokens |

The response limit counts every received byte. The event limit counts bytes before LF; with CRLF, the CR is counted and then removed before JSON decoding.

## Version 1 request

Every request has this outer shape. The app sorts object keys when it encodes the body, although JSON consumers must not depend on key order.

~~~json
{
  "context": {
    "includeSchemaInPrompt": false,
    "reasoningLevel": "custom:fixture-custom"
  },
  "enabledTools": [],
  "metadata": {
    "estimatedInputTokens": 55,
    "evalCaseID": "7AC66DFE-9354-4B5D-88EA-C221AFD0CEDC",
    "evalRunID": "02AADB6F-4603-4A7A-BE38-87FE4148A7CB",
    "foundationEvalsGenerationStarted": 810314406.127609,
    "imageInputTokenCountAvailable": true,
    "repetition": 1
  },
  "mode": "text",
  "options": {
    "maximumResponseTokens": 256,
    "sampling": {
      "kind": "randomTopK",
      "seed": 73,
      "topK": 41
    },
    "temperature": 0.7,
    "toolCallingMode": "disallowed"
  },
  "protocolVersion": 1,
  "provider": {
    "capabilities": [
      "reasoning"
    ],
    "contextSize": 8192
  },
  "requestID": "828C02F3-DC6A-44E4-8BD0-55C5D6E8660F",
  "transcript": {
    "transcript": {
      "entries": [
        {
          "contents": [
            {
              "id": "F4F4A218-C4F3-47EB-9130-AE8B8F61B0B5",
              "text": "Answer accurately and concisely.",
              "type": "text"
            }
          ],
          "id": "2B8E8AED-0C62-4844-ACF4-5D264348A044",
          "role": "instructions"
        },
        {
          "contents": [
            {
              "id": "01B68EFA-937F-4781-923D-2AF8EBCF9306",
              "text": "Hello",
              "type": "text"
            }
          ],
          "contextOptions": {
            "includeSchemaInPrompt": false,
            "reasoningLevel": "fixture-custom"
          },
          "id": "000427AC-8F0B-455E-8007-DB3720D9C2AE",
          "metadata": {
            "estimatedInputTokens": 55,
            "evalCaseID": "7AC66DFE-9354-4B5D-88EA-C221AFD0CEDC",
            "evalRunID": "02AADB6F-4603-4A7A-BE38-87FE4148A7CB",
            "foundationEvalsGenerationStarted": 810314406.127609,
            "imageInputTokenCountAvailable": true,
            "repetition": 1
          },
          "options": {
            "maximumResponseTokens": 256,
            "randomSeed": 73,
            "temperature": 0.7,
            "toolCallingMode": "disallowed",
            "topK": 41
          },
          "role": "user"
        }
      ]
    },
    "type": "FoundationModels.Transcript",
    "version": "1.1"
  }
}
~~~

This is a native request capture formatted with indentation. It confirms `custom:fixture-custom` for a custom reasoning name, `false` for **Omit schema**, and the shown top-K, seed, temperature, response-token, and tool-calling values. A separate capture confirmed `light` for light reasoning. **Framework default** omits `includeSchemaInPrompt`; **Omit schema** sends `false`.

Optional values are omitted from the encoded JSON when unset. They are not emitted as `null`. Arrays and required objects are still present when empty.

| Field | Required | Meaning |
|---|---|---|
| `protocolVersion` | Yes | Integer `1`. Reject versions the backend does not implement. |
| `requestID` | Yes | UUID generated by Foundation Models for this response turn. |
| `mode` | Yes | `text` when `schema` is absent; `guided` when `schema` is present. |
| `transcript` | Yes | The current Foundation Models `Transcript`, encoded through its public `Codable` conformance. |
| `enabledTools` | Yes | Tools available for this turn. Each item has `name`, `description`, and `parameters`. |
| `schema` | Guided only | The requested Foundation Models `GenerationSchema`, encoded through its public `Codable` conformance. |
| `options` | Yes | Generation options. Its members are optional. |
| `context` | Yes | Context options. Its members are optional. |
| `provider` | Yes | The context size and capabilities configured in the suite. This is the app's declaration to Foundation Models, echoed so the backend can validate it. |
| `metadata` | Yes | Foundation Models request metadata converted to ordinary JSON values. Values may be null, Boolean, number, string, array, or object. |

### Generation options

`options.sampling` is omitted for framework-selected sampling. When present, it has one of these shapes:

~~~json
{"kind":"greedy"}
{"kind":"randomTopK","topK":41,"seed":73}
{"kind":"randomProbabilityThreshold","probabilityThreshold":0.9,"seed":73}
~~~

`seed` is optional for both random modes. The remaining optional members are:

| Field | Values |
|---|---|
| `temperature` | JSON number |
| `maximumResponseTokens` | JSON integer |
| `toolCallingMode` | `allowed`, `required`, or `disallowed` |

An SDK sampling or tool-calling case unknown to this adapter fails before the HTTP request rather than being approximated.

### Context options

`context.includeSchemaInPrompt` is `true`, `false`, or absent. The absence preserves Foundation Models' default policy.

`context.reasoningLevel` is absent or one of:

~~~text
light
moderate
deep
custom:<name>
~~~

The `custom:` prefix is part of the version 1 outer protocol. For example, the custom name `fixture-custom` becomes `custom:fixture-custom`. Backends should read the outer `context` object for these normalized values; the SDK-encoded transcript may represent its own recorded context options differently.

### Capabilities

`provider.capabilities` contains zero or more of these exact strings, in this order when enabled:

~~~text
vision
guidedGeneration
reasoning
toolCalling
~~~

These values come from the suite configuration. A backend should fail a request it cannot honor, and the suite should advertise only capabilities the backend actually implements.

## Transcript, schemas, and images

`transcript`, `schema`, and each tool's `parameters` use the public Codable representation supplied by the Foundation Models SDK installed with the app:

- `transcript` is a complete `FoundationModels.Transcript` document. It can contain instructions, prompts, prior responses, reasoning, tool calls, tool outputs, request options, metadata, and attachments.
- `schema` and `enabledTools[].parameters` are `FoundationModels.GenerationSchema` documents. They are not JSON Schema documents.
- The outer protocol version does not freeze the internal shape or version of these Apple documents. A backend should check their `type` and `version` markers where present, tolerate unknown fields, and fail clearly when it cannot interpret an SDK representation.

Vision input has no separate top-level `images` field. Prompt images remain attachment segments inside the encoded transcript, using the SDK's attachment representation. The adapter does not create a second path, URL, or byte-array contract for them.

An image-reference **tool argument** is a different boundary. A generated `ImageReference` identifies an attachment already in the session by its label. When Foundation Evals resolves that reference and invokes a configured custom-tool HTTP endpoint, it sends only this safe metadata shape inside the tool arguments:

~~~json
{
  "kind": "imageReference",
  "attachmentLabel": "receipt",
  "width": 1200,
  "height": 900,
  "orientation": 1
}
~~~

That custom-tool payload does not contain a local path, URL, or image bytes. This tool-execution format is separate from the custom model provider request described on this page.

## Version 1 response events

Return a 2xx response whose body contains one JSON object per line. The adapter decodes these event kinds:

| `kind` | Required fields | Optional fields | Effect |
|---|---|---|---|
| `response` | `content`, `tokenCount` | `action`, `entryID`, `segmentID` | Appends or replaces ordinary response text. Valid only for `mode: text`. |
| `guidedResponse` | `content`, `tokenCount` | `action`, `entryID`, `segmentID` | Appends or replaces guided JSON text. Valid only for `mode: guided`. |
| `reasoning` | `content`, `tokenCount` | `action`, `entryID`, `segmentID` | Appends or replaces visible reasoning text. |
| `reasoningSignature` | `signatureBase64`, `tokenCount` | `entryID` | Updates the opaque reasoning signature. |
| `toolCall` | `callID`, `toolName`, `content`, `tokenCount` | `action`, `entryID` | Appends a JSON argument fragment to a tool call. Only `append` is valid. |
| `usage` | `usageTarget`, `usage` | None | Updates cumulative usage on the response, reasoning, or tool-call channel. |
| `error` | None | `code`, `message` | Immediately fails the request with the provider's safe error code and message. |

`action` is `append` or `replace` and defaults to `append`. `replace` identifies the text segment to replace through `segmentID`. Providers should keep `entryID`, `segmentID`, and `callID` stable across chunks that belong to the same logical output.

Every text, reasoning, signature, or tool-call event requires a nonnegative `tokenCount`. Unknown JSON properties are ignored, but an unknown event kind, action, or usage target is invalid.

### Text stream

This valid response produces `Deterministic fixture stream.`:

~~~ndjson
{"kind":"response","action":"append","entryID":"fixture-response","segmentID":"fixture-response-text","content":"Deterministic ","tokenCount":2}
{"kind":"response","action":"append","entryID":"fixture-response","segmentID":"fixture-response-text","content":"fixture ","tokenCount":1}
{"kind":"response","action":"append","entryID":"fixture-response","segmentID":"fixture-response-text","content":"stream.","tokenCount":1}
{"kind":"usage","usageTarget":"response","usage":{"inputTokens":12,"cachedInputTokens":0,"outputTokens":4,"reasoningTokens":0}}
~~~

For a guided request, use `guidedResponse`. Its `content` chunks must form the requested JSON value:

~~~ndjson
{"kind":"guidedResponse","action":"append","entryID":"fixture-guided-response","segmentID":"fixture-guided-json","content":"{\"answer\":\"","tokenCount":2}
{"kind":"guidedResponse","action":"append","entryID":"fixture-guided-response","segmentID":"fixture-guided-json","content":"fixture","tokenCount":1}
{"kind":"guidedResponse","action":"append","entryID":"fixture-guided-response","segmentID":"fixture-guided-json","content":"\"}","tokenCount":1}
{"kind":"usage","usageTarget":"response","usage":{"inputTokens":12,"cachedInputTokens":0,"outputTokens":4,"reasoningTokens":0}}
~~~

A `response` event in guided mode and a `guidedResponse` event in text mode are rejected.

### Reasoning and signatures

Reasoning events use the reasoning channel and may be interleaved with response events:

~~~ndjson
{"kind":"reasoning","action":"append","entryID":"why-1","segmentID":"why-text","content":"Check the input.","tokenCount":3}
{"kind":"reasoningSignature","entryID":"why-1","signatureBase64":"yv4=","tokenCount":0}
~~~

`signatureBase64` must decode as Base64. The adapter treats it as opaque data.

### Usage

`usageTarget` is `response`, `reasoning`, or `toolCalls`. The `usage` object always contains all four integer fields:

~~~json
{
  "inputTokens": 10,
  "cachedInputTokens": 2,
  "outputTokens": 5,
  "reasoningTokens": 1
}
~~~

Usage is a cumulative snapshot for the selected channel, not a per-chunk delta. All counts must be nonnegative, `cachedInputTokens` must not exceed `inputTokens`, and `reasoningTokens` must not exceed `outputTokens`.

Usage events are optional. When a backend emits them, their counts become the usage Foundation Models reports to the app.

## Tool-call continuation

A tool call is streamed as argument JSON text. This example requests `lookupOrder`:

~~~ndjson
{"kind":"toolCall","action":"append","entryID":"calls-1","callID":"call-1","toolName":"lookupOrder","content":"{\"orderID\":\"A-104\"}","tokenCount":4}
{"kind":"usage","usageTarget":"toolCalls","usage":{"inputTokens":12,"cachedInputTokens":0,"outputTokens":4,"reasoningTokens":0}}
~~~

`content` may arrive in multiple `toolCall` events. Each event appends arguments for the same `callID` and must include `toolName`. `replace` is not supported for tool calls. The completed argument text must be valid JSON for the matching definition in `enabledTools`.

Foundation Models executes the selected app tool after the first provider response ends. If the conversation continues, it invokes the provider again with a new `requestID`; the next request's `transcript` contains the tool call and tool output. The backend then returns another tool call or the final response. The adapter does not call a custom-tool HTTP endpoint on behalf of the provider itself; that execution belongs to the tool registered in the Foundation Models session.

Each HTTP response must contain at least one `response`, `guidedResponse`, or `toolCall` event. Reasoning, signatures, and usage alone do not complete a response turn.

## Failure behavior

The adapter fails the active generation when any of these conditions occurs:

- the endpoint or configured timeout/context size is invalid;
- the encoded request, entire response, or individual event exceeds its byte limit;
- the connection fails, times out, or is cancelled;
- the endpoint returns a non-2xx status or a redirect;
- an NDJSON line is not a valid event object;
- a required event field is missing or a token/usage value is invalid;
- text and guided event kinds do not match the request mode;
- a reasoning signature is not valid Base64;
- a `toolCall` uses `replace`;
- the provider sends an `error` event; or
- the stream reaches EOF without any response, guided-response, or tool-call event.

An error event can supply both fields:

~~~ndjson
{"kind":"error","code":"modelUnavailable","message":"The local model is not loaded."}
~~~

If omitted, `code` defaults to `backendError` and `message` defaults to `The custom provider reported an error.` The message is surfaced through the run failure, so send text that is safe for the app to display and persist.

The adapter checks task cancellation before the request and while consuming bytes. A cancelled or failed stream is not resumed automatically.

## Deterministic fixture

The repository includes [`examples/custom_model_fixture_server.py`](../examples/custom_model_fixture_server.py) for protocol and UI acceptance. It emits fixed responses and does not perform inference:

~~~sh
python3 examples/custom_model_fixture_server.py
~~~

The default port is `19096`. `--port 0` asks the operating system to choose a free loopback port. The main routes are:

| Route | Behavior |
|---|---|
| `/generate` | Selects guided, tool, reasoning, or text behavior from the request. |
| `/text` | Streams three delayed `response` chunks. |
| `/guided`, `/guided/simple`, `/guided/order` | Return deterministic guided JSON. |
| `/guided/stream` | Streams three delayed `guidedResponse` chunks that form `{"answer":"fixture"}`. |
| `/reasoning` | Emits reasoning, then a delayed response. |
| `/tool` | Emits a tool call on the first turn and a final response after the transcript contains tool output. |
| `/tool/execute` | Implements the fixture's separate `lookupOrder` custom-tool endpoint. |
| `/malformed`, `/error`, `/http-error`, `/timeout`, `/cancel`, `/redirect` | Exercise the corresponding failure or cancellation path. |

Use `--stream-delay`, `--timeout-delay`, and `--cancel-delay` to adjust fixture timing.

### Opt-in request capture

Pass `--request-log PATH` to append each validated version 1 provider request as compact NDJSON:

~~~sh
python3 examples/custom_model_fixture_server.py \
  --request-log /tmp/foundation-evals-provider-requests.ndjson
~~~

Request logging is disabled by default. It records complete provider envelopes, which can include prompts, instructions, conversation history, tool definitions and outputs, attachment representations, schemas, and metadata. Use it only with test data, protect the output as sensitive, and remove it when the capture is no longer needed.

The fixture bounds each canonical logged request to 8 MiB and serializes concurrent appends. It logs provider-protocol routes only; requests to the separate `/tool/execute` custom-tool endpoint are excluded. If the selected log cannot be written, the fixture returns HTTP 500 instead of silently losing the capture.
