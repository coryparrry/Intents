<div align="center">

<img src=".github/assets/readme-banner.png" alt="Foundation Evals logo on a coral and turquoise background." width="960">

**Put Apple's Foundation Models to the test.**

Build an evaluation. Inspect the evidence. See what changed.

<img src=".github/assets/foundation-evals-demo.gif" alt="Foundation Evals walkthrough: inspect the workflow trace timeline, span details, and evaluation report." width="960">

![macOS 27+](https://img.shields.io/badge/macOS-27%2B-111827?style=flat-square&logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-F05138?style=flat-square&logo=swift&logoColor=white)
![Apple Foundation Models](https://img.shields.io/badge/Apple-Foundation_Models-2563eb?style=flat-square)
![MCP](https://img.shields.io/badge/Agent_Integration-MCP-7c3aed?style=flat-square)
[![MIT License](https://img.shields.io/badge/License-MIT-16a34a?style=flat-square)](LICENSE)

[Install](#install) · [First evaluation](#run-your-first-evaluation) · [Models and tools](#models-and-tools) · [Connect an agent](#connect-an-agent) · [Build from source](#build-from-source)

</div>

Foundation Evals is a native macOS workbench for testing Apple's Foundation Models. Create repeatable suites, inspect responses and execution traces, and compare saved runs as you refine prompts, settings, and tools. Its built-in MCP server lets a coding agent use the same evaluation workflow, with every run available to review in the app.

## What you can do

| Capability | What it gives you |
|---|---|
| **Repeatable evaluations** | Test cases with shared instructions, attachments, and multiple repetitions. |
| **Flexible scoring** | Exact matches, required text, AI rubrics, or response collection without scoring. |
| **Execution traces** | A nested workflow waterfall with measured native stages, tool activity, token usage and a selected-span inspector. [Trace details](docs/workflow-traces.md). |
| **Saved comparisons** | Run history, baseline comparisons, and JSON reports. |
| **Models and tools** | Apple's on-device model, compatible Core AI models, custom HTTP providers, and configurable tools. |
| **Agent integration** | An included MCP server for managing suites, running evaluations, and inspecting results. |

## Install

Requirements:

- macOS 27 or later
- A Mac that supports Apple Intelligence
- Apple Intelligence enabled and the on-device model downloaded

1. Download and open the latest **Foundation Evals.dmg**.
2. Drag **Foundation Evals** onto the **Applications** shortcut in the window.
3. Eject the **Foundation Evals** disk, then open the app from **Applications** and check that the model is ready.

The app is signed with Developer ID and notarized by Apple.

Xcode is only needed to build from source.

## Run your first evaluation

1. Open **Suite Editor** and enter the instructions shared by your test cases.
2. Add cases with a prompt and, where appropriate, an expected response or reference answer. You can attach text, JSON, CSV, PDF, and image files as context.
3. Choose a scoring mode and set the number of repetitions.
4. Click **Run**. Select a result to inspect its response, score, explanation, timing, token usage, and tool activity.
5. Reopen runs from **Run History**, choose a saved baseline to compare results, or export a JSON report.

| Scoring mode | Use it for |
|---|---|
| **Exact text** | Matching the complete expected response, ignoring surrounding whitespace. |
| **Contains text** | Checking for required text, ignoring case and accents. |
| **AI rubric** | Assessing concrete requirements on a 1–4 scale; scores of 3 or 4 pass. |
| **Collect only** | Saving responses and traces without assigning a score. |

For AI rubrics, write one observable requirement per line and provide a verified reference answer for factual tasks. Inspect the judge's explanation alongside its score. Repetitions help reveal variation; a few runs do not establish statistical significance.

## Models and tools

The default provider is Apple's on-device Foundation Model. You can also load a compatible [Core AI model](docs/coreai-provider.md) or connect a [custom local HTTP provider](docs/custom-provider-protocol.md).

Use the **Features** page to configure custom tools, structured output, streaming, and tool workflows. The [tools and structured output guide](docs/foundation-model-features.md) includes a runnable local HTTP example.

## Connect an agent

Foundation Evals includes an MCP server so an agent can manage suites and references, run evaluations, inspect traces, and compare saved results.

To connect Codex:

1. Open **Settings** in Foundation Evals.
2. Choose **Connect to Codex**.
3. Restart Codex and keep Foundation Evals open.

The server provides an agent workflow guide during MCP initialization. Its HTTP endpoint is `http://127.0.0.1:17873/mcp` while the connector is running.

The connector listens only on this Mac and does not require credentials. Connected local clients can read and change evaluation data.

## Your data

Suites, imported attachments, and run history are saved in `~/Library/Application Support/FoundationEvals/`. The app does not encrypt these files itself. Saved traces and JSON exports can include prompts, responses, reference content, and tool arguments and outputs; review them before sharing.

On-device evaluations run locally. Custom HTTP providers and tools receive the content needed for their calls, and those separate services control any onward network use. Optional Private Cloud Compute uses Apple's network service when available. Spotlight tools can make matching local file content available to the selected model.

Anonymous usage telemetry is **on by default** and can be turned off at any time in **Settings → Privacy → Share usage statistics**. It sends only app-open events, app/macOS versions, and a random installation identifier to PostHog. The identifier is not linked to your name, email, or Apple account. **AI evaluations, inputs, outputs, results, and evaluation activity are not tracked.** Prompts, responses, suite names, files, provider addresses, credentials, screen recordings, and automatic interaction tracking are excluded. Turning telemetry off clears pending events and resets the analytics identifier; it does not delete events already received by PostHog. See [telemetry details](docs/telemetry.md).

## Build from source

Use Xcode 27 with its command-line tools selected. From the repository root:

```sh
./script/build_and_run.sh
```

This creates and opens a development build at `dist/Foundation Evals.app`. Quit the app before rebuilding. You can also open `FoundationEvals/FoundationEvals.xcodeproj` directly in Xcode.

Run the native tests on macOS 27 by opening the project in Xcode and choosing **Product > Test** with development signing configured. You can also use the command line:

```sh
xcodebuild -project FoundationEvals/FoundationEvals.xcodeproj \
  -scheme FoundationEvals -configuration Debug \
  -destination 'platform=macOS' test
```

UI tests require an interactive Mac and a signed test runner. If macOS rejects a command-line UI runner before launch, run the tests directly from Xcode. The optional Core AI inference test requires compatible model resources.

GitHub-hosted CI executes production scoring, structured-field assertion, and MCP installer tests with `swift test`, checks workflows/scripts, and compiles the full app and native test bundles. Its current macOS 26 image cannot execute the macOS 27 app or UI tests; run the native suite above before releasing. The portable package shares production source and existing test files with Xcode without lowering the app’s deployment target. See the [release guide](docs/releasing.md) for manually controlled, signed releases through **Release Me** and the local packaging alternative.

## License

Foundation Evals is released under the [MIT License](LICENSE). Dependencies retain their own licenses; see [third-party notices](FoundationEvals/FoundationEvals/Resources/THIRD_PARTY_NOTICES.txt). Separately supplied model resources have their own terms.
