<div align="center">

<img src=".github/assets/readme-banner.png" alt="Intents logo on a coral and turquoise background." width="960">

**Put Apple's Foundation Models to the test.**

Build an evaluation. Inspect the evidence. See what changed.

<img src=".github/assets/foundation-evals-demo.gif" alt="Intents walkthrough: inspect the workflow trace timeline, span details, and evaluation report." width="960">

![macOS 27+](https://img.shields.io/badge/macOS-27%2B-111827?style=flat-square&logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-F05138?style=flat-square&logo=swift&logoColor=white)
![Apple Foundation Models](https://img.shields.io/badge/Apple-Foundation_Models-2563eb?style=flat-square)
![MCP](https://img.shields.io/badge/Agent_Integration-MCP-7c3aed?style=flat-square)
[![MIT License](https://img.shields.io/badge/License-MIT-16a34a?style=flat-square)](LICENSE)

[Install](#install) · [First evaluation](#run-your-first-evaluation) · [Review outputs](docs/EVAL_REVIEW_GUIDE.md) · [Batch runs](docs/PRODUCTION_EVALS_GUIDE.md) · [User wiki](docs/wiki/Home.md) · [Models and tools](#models-and-tools) · [Connect an agent](#connect-an-agent) · [Build from source](#build-from-source)

</div>

Intents is a native macOS workbench for testing Apple's Foundation Models. Create repeatable suites, inspect responses and execution traces, and compare saved runs as you refine prompts, settings, and tools. Review saved outputs, turn confirmed failures into regression cases, check a judge against held-out examples, and run resumable batches. Its authenticated MCP server lets a coding agent work with the same projects, suites, evidence, and batch store as the app.

## What you can do

| Capability | What it gives you |
|---|---|
| **Repeatable evaluations** | Test cases with shared instructions, attachments, and multiple repetitions. |
| **Flexible scoring** | Exact matches, required text, AI rubrics, or response collection without scoring. |
| **Execution traces** | A nested workflow waterfall with measured native stages, tool activity, token usage and a selected-span inspector. [Trace details](docs/workflow-traces.md). |
| **Human review and regression cases** | Review outputs with AI judgments initially hidden, tag confirmed failure patterns, and promote verified failures into new cases. [Review guide](docs/EVAL_REVIEW_GUIDE.md). |
| **Judge checks** | Separate Development and Held-out examples; inspect false acceptance, false rejection, and unavailable evidence. |
| **Production batches** | Immutable datasets, resumable jobs, unattended workers, captured-output review, cohort gates and audited evidence. [Production guide](docs/PRODUCTION_EVALS_GUIDE.md). |
| **Saved comparisons** | Run history, baseline comparisons, and JSON reports. |
| **Models and tools** | Apple's on-device model, compatible Core AI models, custom HTTP providers, and configurable tools. |
| **Agent integration** | Authenticated controls for the shared workspace, evaluations, batches, review, developer runners, and Intent Lab. [MCP guide](docs/MCP_CONTROL_GUIDE.md). |
| **App feature runners** | A public Swift package for evaluating real app closures on a paired iPhone, iPad, or Mac. [Integration guide](docs/DEVELOPER_SWIFT_INTEGRATION.md). |
| **Intent Lab** | Run frozen App Intent and recognised-text Siri scenarios from a developer-owned UI-test target, then inspect separately labelled evidence. [Setup guide](docs/wiki/Intent-Lab.md). |

## Install

Requirements:

- macOS 27 or later
- For the default on-device model: a Mac that supports Apple Intelligence, with Apple Intelligence enabled and the model downloaded

1. Download the installer from the [latest release](https://github.com/coryparrry/Intents/releases/latest) and open **Intents.dmg**.
2. Drag **Intents** onto the **Applications** shortcut in the window.
3. Eject the **Intents** disk, then open the app from **Applications** and check that the model is ready.

The app is signed with Developer ID and notarized by Apple.

Or install the same signed app with [Homebrew](https://brew.sh):

```sh
brew install --cask coryparrry/tap/intents
```

The cask requires Apple Silicon and macOS 27 or later. New published releases
update the tap automatically. To upgrade through Homebrew, run
`brew update && brew upgrade --cask --greedy coryparrry/tap/intents`.
The app also includes **Check for Updates**.

Xcode is needed to build from source or use Intent Lab. It is not needed for a normal on-device suite.

## Run your first evaluation

1. In **Overview**, create a suite. Open **Cases** and add prompts with an expected response or reference answer where appropriate.
2. Use **Setup → Instructions** for shared instructions and text, JSON, CSV, PDF, or image reference files.
3. Use **Setup → Scoring** to choose a method and number of repetitions.
4. Click **Run**. Open the saved run's **Workflow trace** or **Report** to inspect its response, score, explanation, timing, token usage, and tool activity.
5. Reopen runs from **Results** or the sidebar, use **Compare** for earlier runs, or export a JSON report. See the [user wiki](docs/wiki/Home.md) for detailed steps.

| Scoring mode | Use it for |
|---|---|
| **Exact text** | Matching the complete expected response, ignoring surrounding whitespace. |
| **Contains text** | Checking for required text, ignoring case and accents. |
| **AI rubric** | Assessing concrete requirements on a 1–4 scale; scores of 3 or 4 pass. |
| **Collect only** | Saving responses and traces without assigning a score. |

For AI rubrics, write one observable requirement per line and provide a verified reference answer for factual tasks. Inspect the judge's explanation alongside its score. Repetitions help reveal variation; a few runs do not establish statistical significance.

## Review and improve a result

Open **Review → Samples** after a saved run. Read the output before revealing its AI judgment, save a human verdict and note, and tag observable failures. **Patterns** groups confirmed failures; **Create regression case** requires a verified expected answer. **Judge checks** replays recorded outputs against human decisions in separate Development and Held-out groups. See the [Review guide](docs/EVAL_REVIEW_GUIDE.md).

Human review, judge calibration, and baseline approval are separate decisions. Batch baselines require explicit approval of the current evidence; changed results, reviews, or controls invalidate it. Read the saved [release evidence](docs/wiki/Runs-and-results.md) before relying on a passing gate.

## Models and tools

The default provider is Apple's on-device Foundation Model. You can also load a compatible [Core AI model](docs/coreai-provider.md) or connect a [custom local HTTP provider](docs/custom-provider-protocol.md).

Use the suite's **Setup** pages to configure custom tools, structured output, streaming, and tool workflows. The [tools and structured output guide](docs/foundation-model-features.md) includes a runnable local HTTP example.

To evaluate the production Swift feature inside another app, add the
`FoundationEvalsDeveloper` package product and host its explicitly paired runner.
The [developer integration guide](docs/DEVELOPER_SWIFT_INTEGRATION.md) covers typed
closures, `@Generable` results and tools, iPhone/iPad/Mac setup, trust, cancellation,
saved run evidence, and the boundary with Apple's development-only Evaluations framework.

For large batches, open **Batch runs** in the sidebar. Freeze the current suite or import JSONL, create a batch, and run it on a matching Mac. The [production guide](docs/PRODUCTION_EVALS_GUIDE.md) covers `intents-evals`, unattended native workers, target matrices, schedules and opt-in capture.

## Connect an agent

Intents includes an authenticated MCP server for projects and suites, references, runs, review suggestions, batch jobs, developer runners, and Intent Lab. Changes appear in the same native workspace. The standalone Apple Foundation Evals plugin uses a separate store.

To connect Codex:

1. Open **Settings** in Intents.
2. Choose **Connect to Codex**.
3. Restart Codex and keep Intents open.

The server provides an agent workflow guide during MCP initialization. Start with workspace state, then use `eval_find_actions` and `eval_describe_action` to load the exact schemas needed for advanced work. Mutations use revisions, confirmations where required, and operation IDs for safe retries. See the [MCP control guide](docs/MCP_CONTROL_GUIDE.md). Its HTTP endpoint is `http://127.0.0.1:17873/mcp` while the connector is running.

The connector listens only on this Mac. Intents generates a bearer credential, stores it in the login Keychain, and configures Codex to send it. Connected authenticated local clients can read and change evaluation data; keep the managed configuration private.

## Your data

Suites, imported attachments, and run history are saved in `~/Library/Application Support/FoundationEvals/`. The app does not encrypt these files itself. Saved traces and JSON exports can include prompts, responses, reference content, and tool arguments and outputs; review them before sharing.

On-device evaluations run locally. Custom HTTP providers and tools receive the content needed for their calls, and those separate services control any onward network use. Optional Private Cloud Compute uses Apple's network service when available. Spotlight tools can make matching local file content available to the selected model.

Anonymous usage telemetry is **on by default** and can be turned off at any time in **Settings → Privacy → Share usage statistics**. It sends only app-open events, app/macOS versions, and a random installation identifier to PostHog. The identifier is not linked to your name, email, or Apple account. **AI evaluations, inputs, outputs, results, and evaluation activity are not tracked.** Prompts, responses, suite names, files, provider addresses, credentials, screen recordings, and automatic interaction tracking are excluded. Turning telemetry off clears pending events and resets the analytics identifier; it does not delete events already received by PostHog. See [telemetry details](docs/telemetry.md).

## Build from source

Use Xcode 27 with its command-line tools selected. From the repository root:

```sh
./script/build_and_run.sh
```

This creates and opens a development build at `dist/Intents.app`. Quit the app before rebuilding. You can also open `FoundationEvals/FoundationEvals.xcodeproj` directly in Xcode.

Run native tests on macOS 27 by opening the project in Xcode and choosing **Product > Test** with development signing configured.

Run the isolated production package checks and build its CLI without launching the app:

```sh
swift test --package-path Packages/ProductionEvals -j 2
swift build --product intents-evals -j 2
python3 script/test_production_evals.py .build/debug/intents-evals
```

Run the app tests with:

```sh
xcodebuild -project FoundationEvals/FoundationEvals.xcodeproj \
  -scheme FoundationEvals -configuration Debug \
  -destination 'platform=macOS' test
```

UI tests require an interactive Mac and a signed test runner. If macOS rejects a command-line UI runner before launch, run the tests directly from Xcode. The optional Core AI inference test requires compatible model resources.

GitHub CI classifies the complete pull request or `main` push diff, including deletions and both sides of renames. Linux workflow linting, shell checks, and Python example syntax checks remain lightweight and always run; unit tests and macOS jobs follow the affected code.

| Changed files | Unit tests | Native build |
|---|---|---|
| Docs, README artwork, demo media, GitHub funding or ownership metadata | None | Skipped |
| Release workflows and Python/shell tools | Related script modules; signature checks use macOS when affected | Skipped unless build tooling changes |
| Portable scoring, installer, or UI component source | Suites that use the changed source, including shared dependencies | App and unit-test bundle; UI-test bundle when UI is affected |
| Other app source | No unrelated portable suites; this code needs the native macOS 27 test environment | App and unit-test bundle; UI-test bundle when UI is affected |
| Test files | Changed portable/script suites; app-only tests compile in their native target | Relevant native test target, if applicable |
| CI routing, package/project settings, release version files, or unknown paths | Full coverage | Full build |

Manual runs, malformed events, and unavailable Git history select full coverage. Release PR version changes still require the complete source checks used by installer publication. The **Route changed files** summary lists the selected suites and the reasons for each decision. Empty selections run no unit tests; a selected Swift suite that cannot be discovered fails instead of silently passing with zero tests.

The explicit portable-source dependency map lives in `script/ci_routes.py`. Update it when adding a suite or a shared dependency; catalog tests check it against `Package.swift` and the test suite names. The portable package shares production source and existing tests with Xcode without lowering the app’s deployment target. CI uses the hosted `xcode-27` macOS 27 runner, runs the core test scheme, and builds (but does not run) the UI-test bundle when UI code changes. Run the interactive UI tests above before releasing. See the [release guide](docs/releasing.md) for signed releases through **Release Me** and local packaging.

## License

Intents is released under the [MIT License](LICENSE). Dependencies retain their own licenses; see [third-party notices](FoundationEvals/FoundationEvals/Resources/THIRD_PARTY_NOTICES.txt). Separately supplied model resources have their own terms.
