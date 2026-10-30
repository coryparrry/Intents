COMPARE YOUR OPTIONS

# Intents vs Apple’s Evaluations framework

Checked 30 October 2026 · Intents 1.5.2

## Short answer

Apple’s Evaluations framework integrates Swift evaluation code with your app’s test targets and Swift Testing. Intents is a native Mac workbench for creating suites, inspecting saved responses and traces, and working through Review, Batch runs, or MCP. Use Apple’s framework for tests close to your implementation; use Intents for an interactive evaluation workspace. They can complement each other.

## Who should stay with Apple’s framework?

Choose Apple Evaluations when datasets, metrics, and evaluation code belong in your app’s test target. Apple demonstrates the `.evaluates` trait in Swift Testing and reviewing aggregate metrics in its Xcode workflow.

## Who should try Intents?

Try Intents when you want to iterate on Apple model cases and inspect evidence without writing an evaluation harness for every ordinary suite. Connect a coding agent through authenticated local MCP when that fits your work.

| Detail | Intents 1.5.2 | Apple Evaluations framework |
| --- | --- | --- |
| Workflow | Native Mac workspace | Swift code in app test targets |
| Authoring | Cases and scoring in the app | Typed datasets, evaluators, metrics |
| Apple Foundation Models | Built-in on-device provider | Supported by the framework |
| Xcode required | Not for ordinary model suites | Xcode / Swift Testing workflow |
| Evidence | Saved reports, traces, comparisons | Evaluation results and aggregate metrics |
| MCP server | Authenticated localhost connector | check |
| Price and licence | Free, MIT source | check Apple SDK terms |

## Use them together

Explore a failure in Intents, then add a representative case to your app’s own tests. Match inputs, model configuration, and metrics before comparing outcomes. Intents does not replace `.evaluates` inside Swift Testing when that is the integration you need.

## Where fm and the Python SDK fit

Use [fm for a quick terminal prompt check](/guides/fm-cli-to-repeatable-evals), and the [Python SDK for notebooks and Python metric libraries](/compare/apple-fm-python-sdk). Evaluations keeps typed datasets, evaluators and metrics inside app test targets.

## Workflow: from failure to test

Find a failing case in Intents, inspect its trace, and export the JSON report. Then manually add a representative input and expectation to a Swift Testing `.evaluates` evaluation in your app target, following Apple's dataset and evaluator APIs. The report is evidence to translate; no automatic report importer or test generator is claimed.

## Official sources

[Apple: Meet the Evaluations framework](https://developer.apple.com/videos/play/wwdc2026/298/) · [Evaluations documentation](https://developer.apple.com/documentation/evaluations) · [Foundation Models documentation](https://developer.apple.com/documentation/foundationmodels). A “check” cell records a detail not established here.

## Frequently asked questions

### Is Intents Apple’s Evaluations framework?

No. Intents is an independent open-source Mac app. Evaluations is Apple’s framework for app developers.

### Can I use both?

Yes. Use the Mac workspace to explore cases and the framework to keep evaluations in app test targets.

### Do ordinary Intents model suites need Xcode?

No. Xcode 27 is required for source builds and development-source Mac App Intent tests, not ordinary on-device suites.

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
