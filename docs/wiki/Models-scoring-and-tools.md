# Set models, scoring, and tools

[Home](Home.md) · [Projects and suites](Projects-and-suites.md) · [Runs and results](Runs-and-results.md)

Open a suite's **Setup** page. Its sections are **Instructions**, **Scoring**, **Model**, **Tools**, **Structured output**, **Session profile**, and **Performance**. The settings apply to all cases in that suite. Intents saves them with each run.

A connected app feature uses the model and tools inside that app. See [App feature runners](App-feature-runners.md).

## Select a scoring method

Open **Setup → Scoring** and select a method:

| Method | Pass rule | Use |
|---|---|---|
| **Exact text** | The complete response equals the expected response after removal of outer whitespace. | Use for a known output string. |
| **Contains text** | The response contains the required literal text. Case and accents do not matter. | Use for one required phrase. It is not a regular expression. |
| **AI rubric** | Each requirement scores at least 3 on a scale from 1 to 4. | Use for free-form responses with observable requirements. |
| **Collect only** | Intents gives no text score. JSON field checks can still give a pass or failure. | Use to collect responses and traces first. |

For **AI rubric**, write one observable requirement per line. You can add up to four requirements. The **Use Template** menu has examples. Add a known correct reference answer for a factual case. The judge still applies every requirement when a response matches that answer.

You can use a standalone `exact: "text"` requirement for exact equality within a rubric. Read AI judgments against examples that a person reviewed before you use them as a release gate.

Set **Repetitions** from 1 to 5. If a run exceeds a suite or sample limit, read its readiness message. Use case-level **Field checks** for exact checks on structured JSON.

## Select a model

Open **Setup → Model** and select a provider:

- **On device** runs Apple's Foundation Model on the Mac. It requires Apple Intelligence availability.
- **Private Cloud Compute** uses Apple's cloud model. It requires the correct entitlement, service, network, and quota. Select **Refresh cloud status** to read availability.
- **Custom local HTTP** calls a local model service. Set its endpoint, capabilities, context size, and timeout. The endpoint must use literal `127.0.0.1`. Intents rejects redirects and embedded credentials. See the [provider protocol](https://github.com/coryparrry/Intents/blob/main/docs/custom-provider-protocol.md).
- **Core AI model** loads a compatible folder with metadata, a model, and a tokenizer. Select the folder and **Load Model**. Then read its capabilities. See the [Core AI guide](https://github.com/coryparrry/Intents/blob/main/docs/coreai-provider.md).

The **Generation** controls set sampling, the response limit, an optional seed, and temperature. A token limit can stop a response in the middle of a sentence. Greedy or seeded sampling can improve repeatability. Model or OS changes can still change the output.

**Context and tool limits** set the input ceiling, large-input policy, reference delivery, and shared limit for tool calls. The selected provider decides which features are available.

## Set advanced model behavior

Expand **Setup → Model → Advanced model options**. For the on-device provider, **Use case** can select Apple's content-tagging model. This model can have different capabilities and context limits. **Guardrails** and **Reasoning** depend on the provider. The model can still refuse a request.

**Schema guidance** and **Tool calling** affect how the model receives structured-output and tool instructions. A required tool call on every request can use the call limit quickly. The section also contains vision tools, error-history settings, and prewarm settings. Saved settings still apply while the section is collapsed.

If you need full transcript evidence, enable **Save full public transcript** under **Transcript and errors** before a run. It saves instructions, prompts, responses, tool inputs, tool outputs, and reference passages. JSON exports include this content. It can also support Apple feedback attachment export.

**On generation error** can keep a failed request and partial response in the session history. Alternatively, it can restore the history to its earlier state. You cannot export content that the app discards. Save only the evidence that you need.

## Give the model tools

Open **Setup → Tools** to set Spotlight search or add custom tools. **Add Sample** creates a `lookupOrder` tool with a saved JSON response. **Add Tool** creates a blank tool. Set its name, description, argument schema, and implementation.

A saved tool response is a fixture. It does not call code in your app. **Local HTTP bridge** calls a loopback service that you control. See the [tool guide](https://github.com/coryparrry/Intents/blob/main/docs/foundation-model-features.md) for an example.

Custom, reference, image, and Spotlight tools share the **Tool call limit per sample** across turns. Intents saves tool arguments and outputs with the run. If you use a local HTTP service, make sure that you trust it. That service controls any further use of the data.

## Set output, sessions, and performance

- **Setup → Structured output** defines fields for generated JSON. You can set objects, arrays, choices, optional values, and constraints. With no fields, the model returns ordinary text. Add case-level Field checks for fields that must pass.
- **Setup → Session profile** sets behavior across model turns. It can require a tool before the final answer. It can also give instructions after a tool finishes. Read the trace to see the actual calls.
- **Setup → Performance** can show partial response text and request prewarming. Time to first visible content means the first nonempty display update. It is not an exact first-token time. Prewarming does not guarantee lower latency.

If a feature is unavailable for the provider, read the message in Setup or Run readiness. Change the settings before you run the suite.

## Use an independent AI judge

For an AI rubric, **Setup → Scoring** can use the subject model or an independent judge. Add a judge connection in **Intents → Settings → Judges**. Then use the connection's test action. This sends a small test request without evaluation evidence.

An external judge receives the evidence that it needs to score a response. The app shows a disclosure and asks for approval before this transfer. Read that disclosure before you approve it. Intents keeps judge keys in the macOS Keychain.
