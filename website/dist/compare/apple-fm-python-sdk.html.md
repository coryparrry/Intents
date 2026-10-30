# Intents vs Apple's Foundation Models SDK for Python (apple-fm-sdk)

## Short answer

Apple's Foundation Models SDK for Python provides bindings for scripting and evaluating Foundation Models features with Python tooling. Intents is a native Mac workbench with no code needed for ordinary suites, plus saved runs, traces, Review and Batch runs. They are complementary: choose Python for programmable analysis and Intents for an interactive workspace around repeatable cases.

| Detail | Intents 1.5.2 | Apple Python SDK |
| --- | --- | --- |
| Interface | Native Mac workbench | Python scripts and notebooks |
| Language | No code for ordinary suites; Swift source | Python bindings to Foundation Models |
| Install | DMG or brew install --cask coryparrry/tap/intents | pip install apple-fm-sdk |
| Requirements | macOS 27+, Apple silicon; Apple Intelligence and downloaded model for default provider | macOS 26.0+, Python 3.10+, compatible Mac with Apple Intelligence enabled |
| Xcode needed | Only source builds and development-source Mac App Intent tests | Xcode 26.0+ and accepted SDK agreement, per Apple |
| On-device model | Default on-device provider | System foundation model |
| Private Cloud Compute | Optional when available; provider requirements apply | check: the linked Python overview establishes on-device access |
| Tool calling and guided generation | Configurable tools and structured output workflows | Tool protocol and generable schemas |
| Saved runs and traces UI | Saved reports, traces and baseline compare | Build analysis with Python tooling |
| Human review | Review with human verdicts | Implement your review workflow |
| Batch and resumable runs | Batch runs with frozen datasets and resumable jobs | Batch inference in Python; resumable-job API: check |
| MCP for coding agents | Authenticated local MCP, Connect to Codex | Bundled MCP server: check |
| Licence | MIT | Apache-2.0 source; Apple framework use subject to SDK terms |
| Price | Free | Source available without a purchase; separate service pricing: check |

## Use both

Explore a prompt and inspect failures in Intents. Use Python for notebook analysis, batch inference, your metric libraries, and processing transcripts exported from Swift apps. Match inputs, configuration and scoring before interpreting differences. Intents does not claim to wrap the Python SDK or the fm CLI.

## Who should stay with Python

Stay with Python when your evaluation depends on notebooks, custom metric libraries or a scripted pipeline. Apple's SDK supports on-device responses, tool calling and guided generation.

## Who should try Intents

Try Intents when you want to author ordinary suites without code, inspect per-case evidence, compare a saved baseline, add human verdicts, or resume a batch in a Mac UI. MCP lets a coding agent work with the local workspace.

## Sources

[Apple SDK README: requirements and install](https://github.com/apple/python-apple-fm-sdk) · [Apple Python SDK documentation](https://apple.github.io/python-apple-fm-sdk/) · [Apache-2.0 licence](https://github.com/apple/python-apple-fm-sdk/blob/main/LICENSE.md) · [WWDC26: fm CLI and Python SDK](https://developer.apple.com/videos/play/wwdc2026/334/). A “check” cell is not established by these sources.

## Frequently asked questions

### Does the Python SDK need Xcode?

Apple lists Xcode 26.0 or later with its SDK agreement accepted. Ordinary Intents suites do not need Xcode.

### Can I keep my Python metric libraries?

Yes. Use Python for custom analysis and use Intents when a saved Mac workspace helps you explore and review cases.

### Does Intents wrap apple-fm-sdk?

No such integration is claimed. Intents and the Python SDK are separate ways to work with Apple Foundation Models.

### Is the SDK open source?

Apple publishes the Python SDK source under Apache-2.0. Intents source is MIT licensed. Apple's framework use also has SDK terms.

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
