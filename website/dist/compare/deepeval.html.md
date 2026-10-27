# Intents vs DeepEval

Canonical page: https://intents-workbench.coryparry.chatgpt.site/compare/deepeval

## Short answer

Choose DeepEval for Python and pytest-based evaluation pipelines, reusable metrics, and tests alongside your application code. Choose Intents for a native Mac interface to Apple Foundation Models suites, saved traces, Review, and Batch runs. DeepEval supports local execution with optional hosted services; Intents keeps its evaluation workspace on your Mac.

## Who should stay with DeepEval?

Keep DeepEval when Python tests and programmable metrics are already central to your project. Its pytest integration lets you run evaluation code in your own environment and CI. It also supports tracing; traces are not exclusive to Intents.

## Who should try Intents?

Try Intents when you prefer building and reviewing Apple model evaluations in a Mac app. You do not need to write Python for an ordinary suite. A small saved case and its response provide a useful starting point before expanding coverage.

| Detail | Intents 1.5.2 | DeepEval |
| --- | --- | --- |
| Interface | Native Mac workbench | Python / pytest runner; optional hosted platform |
| Test definitions | Cases, instructions, scoring settings | Python test cases and metrics |
| Local evidence | Saved runs and traces on the Mac | Local runs; optional Confident AI upload |
| Apple Foundation Models provider | Built in | check |
| Agent workflow | Authenticated local MCP | Coding-agent guidance; check client setup |
| Price model | Free, MIT licensed | Open-source framework; optional commercial Confident AI |
| Hosted service required | No for ordinary on-device suites | No for local framework use |

## Official sources

[DeepEval homepage](https://deepeval.com/) · [DeepEval quickstart](https://deepeval.com/docs/getting-started) · [DeepEval source](https://github.com/confident-ai/deepeval). A “check” cell is unverified here.

## Frequently asked questions

### Does DeepEval require a hosted account?

Its quickstart supports local evaluation. Logging in enables optional sharing with Confident AI.

### Do local evaluations always keep prompts offline?

No. A local runner may call remote models or judges. Check the configured providers in either tool.

### Which suits an existing Python test suite?

DeepEval is the more direct fit for pytest-based evaluation code. Intents is useful for a separate native Mac workflow.

## Try Intents 1.5.2

[Download for macOS · v1.5.2](https://github.com/coryparrry/Intents/releases/download/v1.5.2/Intents-1.5.2-macOS-arm64.dmg) · [Getting started](/getting-started)

```sh
brew install --cask coryparrry/tap/intents
```

Free, MIT licensed, macOS 27+, Apple silicon. Enable Apple Intelligence and download its model for the default on-device provider. Ordinary model suites do not require Xcode.

## Sources and corrections

Facts checked 26 October 2026. [Intents release](https://github.com/coryparrry/Intents/releases/tag/v1.5.2) · [User guide](https://github.com/coryparrry/Intents/blob/v1.5.2/docs/wiki/Home.md) · [MCP guide](https://github.com/coryparrry/Intents/blob/v1.5.2/docs/wiki/Codex-and-MCP.md). [Report a correction](https://github.com/coryparrry/Intents/issues).

[All comparisons](/compare) · [Evaluate on a Mac](/guides/evaluate-apple-foundation-models-mac) · [Connect an agent](/guides/intents-mcp-coding-agents)
