# On-device LLM evaluation on macOS 27 (without sending prompts to a vendor SaaS)

Canonical page: https://intents-workbench.coryparry.chatgpt.site/guides/on-device-llm-evaluation-macos

## Short answer

Use Intents’ default on-device Apple Foundation Model and local scoring to evaluate prompts on an Apple silicon Mac with macOS 27+. Keep remote providers, remote judges, Private Cloud Compute, and network tools out of that suite. The runner being local is not enough by itself: every configured model, judge, and tool determines the data path.

## Choose a local evaluation path

1. Install Intents 1.5.2 and enable Apple Intelligence. Download the model before starting an on-device suite.
2. In **Setup → Model**, choose the ready on-device Apple model and confirm the destination is **This Mac · built-in evaluator**.
3. Start with **Contains text** or **Exact text** scoring and no tools. These literal checks avoid a remote model judge.
4. Review the suite’s provider, scoring, and tools before adding real data. Remote HTTP providers, remote judges, Private Cloud Compute, and network tools have different data paths.
5. Run a small synthetic case. Read the saved report and trace before expanding the dataset.

## What stays on the Mac?

The on-device model processes its prompts locally and Intents saves the workspace and run evidence on the Mac. Exports may include prompts, responses, references, and tool content. Inspect JSON reports before sharing them or attaching them to an issue.

The application can still use a network for updates and configured services. Usage statistics are on by default and can be disabled in **Settings → Privacy → Share usage statistics**. Diagnostic sharing is separate and off by default. These controls are distinct from the provider used for a model evaluation; do not interpret “on-device” as a guarantee that the whole app never uses a network.

## Extend the suite deliberately

When adding a judge or tool, verify its service and inputs first. A custom HTTP provider sends content to its configured endpoint. An authenticated MCP client can read or change evaluation data; review what you authorize the agent to do.

On-device evaluation is useful for product-specific regression cases, not universal claims about a model. Keep the environment and scoring rule with your result, repeat representative cases, and inspect failures.

Read the [data guide](https://github.com/coryparrry/Intents/blob/v1.5.2/docs/wiki/Data-and-troubleshooting.md), [telemetry documentation](https://github.com/coryparrry/Intents/blob/v1.5.2/docs/telemetry.md), and [first-evaluation guide](/guides/evaluate-apple-foundation-models-mac). Compare [Promptfoo](/compare/promptfoo) and [DeepEval](/compare/deepeval) fairly: their runners can also execute locally, with data handling dependent on selected providers.

## Try Intents 1.5.2

[Download for macOS · v1.5.2](https://github.com/coryparrry/Intents/releases/download/v1.5.2/Intents-1.5.2-macOS-arm64.dmg) · [Getting started](/getting-started)

```sh
brew install --cask coryparrry/tap/intents
```

Free, MIT licensed, macOS 27+, Apple silicon. Enable Apple Intelligence and download its model for the default on-device provider. Ordinary model suites do not require Xcode.

## Sources and corrections

Facts checked 30 October 2026. [Intents release](https://github.com/coryparrry/Intents/releases/tag/v1.5.2) · [User guide](https://github.com/coryparrry/Intents/blob/v1.5.2/docs/wiki/Home.md) · [MCP guide](https://github.com/coryparrry/Intents/blob/v1.5.2/docs/wiki/Codex-and-MCP.md). [Report a correction](https://github.com/coryparrry/Intents/issues).

[All comparisons](/compare) · [Evaluate on a Mac](/guides/evaluate-apple-foundation-models-mac) · [Connect an agent](/guides/intents-mcp-coding-agents)

Project page: https://coryparry.dev/projects/intents
