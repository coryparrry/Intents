# From fm respond to repeatable Foundation Models evals on a Mac

## Short answer

Use Apple's fm CLI for a quick prompt check, then turn the useful prompt into an Intents case with explicit scoring and repetitions. Save the result as a baseline and compare after a change. The terminal and native workspace complement each other; this is a manual workflow, not an automatic import or an fm wrapper.

## 1. Make a quick check with fm respond

Apple describes fm as pre-installed on macOS 27. With Apple Intelligence ready, run this prompt form shown in Apple's session:

```sh
fm respond "Provide a basic regex in Swift to parse an email address"
```

The CLI also provides `fm chat` and `fm schema`. Apple's session shows switching chat models with `/model` and saving with `/save`. Check the current help for options; saved chat is not an Intents suite.

## 2. Decide what a repeatable check means

A single useful answer cannot establish consistency or guard against regressions. Define a narrow expected result and representative inputs. Validate generated code separately before using it.

## 3. Turn the prompt into an Intents case

Create a suite and add the prompt in Cases. For a literal example, ask for only `ready` and set Exact scoring with expected response `ready`. Use Contains when a stable phrase is sufficient. In Setup → Scoring, choose repetitions and inspect each response. For the regex task, create representative cases and a verified reference; one Contains check cannot establish regex correctness.

## 4. Save a baseline and compare

Save the run before editing instructions. Change one prompt or model setting, rerun the same cases, and use Compare with the saved baseline. Inspect traces and export a JSON report for the failures you need to investigate. A few repetitions do not establish statistical significance.

## 5. Optionally hand it to a coding agent

Open Settings → MCP Connector and choose Connect to Codex, then restart Codex. Other HTTP MCP clients need manual bearer authentication. Keep Intents open; its authenticated local endpoint is `http://127.0.0.1:17873/mcp`, with a Keychain-managed bearer. Start by reading suite and run evidence. [MCP setup guide](/guides/intents-mcp-coding-agents).

## Sources

[Apple: Build AI-powered scripts with the fm CLI and Python SDK](https://developer.apple.com/videos/play/wwdc2026/334/) · [Apple Foundation Models overview](https://developer.apple.com/foundation-models-framework/) · [Python SDK comparison](/compare/apple-fm-python-sdk) · [Evaluations framework comparison](/compare/apple-evaluations).

## Frequently asked questions

### Does Intents import fm chat history?

This guide describes manually creating a case. It does not claim a chat importer or that Intents uses fm underneath.

### Do I need Xcode for this Intents workflow?

No. Ordinary on-device suites require macOS 27 or later on Apple silicon with Apple Intelligence enabled and its model downloaded. Source builds and unshipped development-source Mac App Intent tests need Xcode 27.

### Can I use fm and Intents together?

Yes. Use fm for a one-off check and Intents to save cases, inspect responses and compare repeatable runs. Match model settings before comparing evidence.

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
