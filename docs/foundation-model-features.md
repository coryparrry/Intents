# Tools, profiles, and structured output

The suite's **Features** page controls tools, profiles, output schemas, and performance options. Settings are saved with the suite and recorded with each run. Available behavior depends on the selected model's capabilities.

## Try a custom tool

1. Open **Features → Tools → Add Sample**. This creates `lookupOrder` with a string `orderID` argument and a saved fixture response.
2. Set a case prompt to `What is the status of order A-104?`. Choose **Contains text** scoring with expected text `shipped`.
3. Open **Features → Profile**, enable **Use an evaluation profile**, and enable **Require the model to call a tool first**. Set **Instructions after tool completion** to `Use the returned order status in the final answer.`
4. Run the suite and inspect the sample's feature trace for arguments, output, call outcome, duration, and profile transitions.

A fixture returns the same saved response on every call. It is useful for testing whether the model selects the right tool and arguments, but it does not execute your application code.

The profile applies its after-tool instructions at the next model transition and removes tools after the first output. Calls already issued concurrently may still finish. Custom, reference, image, and Spotlight tools share the **Tool call limit per sample**, including setup turns.

## Run a local tool implementation

From a source checkout, start the included example:

```sh
python3 examples/order_tool_server.py
```

In the sample tool editor, set **Implementation** to **Local HTTP bridge**, enter `http://127.0.0.1:19000/tool`, and change the expected status to `delivered`. The example derives its response from the generated `orderID`.

The app sends a JSON request:

```json
{"toolName":"lookupOrder","arguments":{"orderID":"A-104"}}
```

Your service should return a successful HTTP status and UTF-8 text or JSON. It can be written in any language; define its arguments in the editor and implement the HTTP handler around your code.

Endpoints must use literal `http://127.0.0.1:<port>/...`. The app rejects its reserved MCP port, URL credentials, query strings, fragments, and redirects. Requests are limited to 16 KiB and arguments to 256 model tokens; responses are limited to 4 KiB and 512 model tokens. The timeout is ten seconds.

Custom tool arguments and outputs are saved in run reports. Only use local services you trust: the app's loopback restriction does not prevent a separate service from forwarding data elsewhere.

To supply an entire model backend instead of a tool, see the [custom provider protocol](custom-provider-protocol.md).

## Require structured output

Open **Features → Output** and use **Add Field** to define the response. For example, add a string field named `status` for the order tool. With no fields, the model returns ordinary text.

Fields support nested objects and arrays, optional values, choices, numeric and string constraints, reusable definitions, and image references. The app builds a generation schema and saves it with the run. Scoring applies to the final serialized JSON through text checks, field assertions, or an AI rubric; choose a metric that matches the structure you expect.

## Streaming and prewarming

Under **Features → Performance**, **Stream the response** displays partial output and records time to first visible content. This measures the first nonempty response update, not an exact first-token timestamp. Final scoring uses the completed response; a cancelled or failed stream is not scored as a completed answer.

**Prewarm the model before each sample** asks the framework to prepare the session. It is a hint, not a guarantee of lower latency. Compare repeated runs with and without prewarming before drawing conclusions.

For image inputs, the framework's tokenizer cannot count the complete image-bearing request. The app reports image input token count as unavailable, estimates admission from countable text and configuration, and lets the model enforce its full context limit during generation. Text-only inputs use the framework token count.
