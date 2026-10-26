# How Intents compares with other LLM evaluation tools

Canonical page: https://intents-workbench.coryparry.chatgpt.site/compare

## Short answer

Intents is a free native Mac workbench for Apple Foundation Models, with suites, traces, Review, Batch runs, and local MCP. Choose it for on-device Apple evaluations in a Mac UI. Consider Promptfoo, DeepEval, or Braintrust for configuration, Python, or hosted workflows; choose Apple Evaluations for Swift Testing inside your app target.

## Compare the working styles

Checked 26 October 2026. “check” means a detail was not verified here, not that the tool lacks it. Local execution does not by itself establish that every provider or judge is offline.

| Detail | Intents | Apple Evaluations | Promptfoo | DeepEval | Braintrust |
| --- | --- | --- | --- | --- | --- |
| UI | Native Mac app | Xcode / test workflow | CLI and browser viewer | Python tests / CLI | Web platform and SDKs |
| Primary OS | macOS 27+, Apple silicon | Apple platforms; minimums: check | Cross-platform; requirements: check | Python environment; OS matrix: check | Browser / SDK host; requirements: check |
| Language | Swift app; no code for suites | Swift | YAML; code extensions | Python / pytest | Multiple SDKs including Python / TypeScript |
| On-device Apple FM | Built in | Supported | check | check | check |
| Local-first evidence | Saved workspace and runs | Results; storage details: check | Local runner and viewer | Local runs without account | Completely local storage: check |
| MCP / agent | Authenticated local MCP | MCP server: check | Tests MCP servers | Agent / MCP system evaluation | MCP integration |
| Hosted SaaS | No required evaluation service | Framework | Optional commercial service | Optional Confident AI | Hosted platform; enterprise options |
| Price model | Free | check SDK terms | Free Community; commercial options | OSS; optional commercial service | Free and paid / usage plans |
| Open source | MIT app source | check | MIT project | Open-source framework | Open-source SDKs |

## What Intents doesn’t do

Intents is not a hosted production observability service or a Python-first testing framework. It does not replace Apple’s `.evaluates` integration when you want evaluations inside Swift Testing. Its website demos are historical HTML recreations, not live model runs or benchmarks.

## Read a comparison

- [Intents vs Foundation Evals](/compare/foundation-evals)
- [Intents vs Promptfoo](/compare/promptfoo)
- [Intents vs DeepEval](/compare/deepeval)
- [Intents vs Braintrust](/compare/braintrust)
- [Intents vs Apple’s Evaluations framework](/compare/apple-evaluations)

## Practical guides

- [How to evaluate Apple Foundation Models on a Mac before you ship](/guides/evaluate-apple-foundation-models-mac)
- [Install Intents with Homebrew on Apple silicon](/guides/install-intents-homebrew)
- [Connect Codex or Claude Code to Intents over MCP](/guides/intents-mcp-coding-agents)
- [On-device LLM evaluation on macOS 27 (without sending prompts to a vendor SaaS)](/guides/on-device-llm-evaluation-macos)

## Official comparison sources

[Apple Evaluations session](https://developer.apple.com/videos/play/wwdc2026/298/) · [Promptfoo introduction](https://www.promptfoo.dev/docs/intro/) · [Promptfoo pricing](https://www.promptfoo.dev/pricing/) · [DeepEval quickstart](https://deepeval.com/docs/getting-started) · [Braintrust docs](https://www.braintrust.dev/docs) · [Braintrust pricing](https://www.braintrust.dev/pricing). Follow each comparison for more specific sources. No ratings, star counts, or numeric prices are assumed.


## Try Intents 1.5.2

[Download for macOS · v1.5.2](https://github.com/coryparrry/Intents/releases/download/v1.5.2/Intents-1.5.2-macOS-arm64.dmg) · [Getting started](/getting-started)

```sh
brew install --cask coryparrry/tap/intents
```

Free, MIT licensed, macOS 27+, Apple silicon. Enable Apple Intelligence and download its model for the default on-device provider. Ordinary model suites do not require Xcode.

## Sources and corrections

Facts checked 26 October 2026. [Intents release](https://github.com/coryparrry/Intents/releases/tag/v1.5.2) · [User guide](https://github.com/coryparrry/Intents/blob/v1.5.2/docs/wiki/Home.md) · [MCP guide](https://github.com/coryparrry/Intents/blob/v1.5.2/docs/wiki/Codex-and-MCP.md). [Report a correction](https://github.com/coryparrry/Intents/issues).

[All comparisons](/compare) · [Evaluate on a Mac](/guides/evaluate-apple-foundation-models-mac) · [Connect an agent](/guides/intents-mcp-coding-agents)
