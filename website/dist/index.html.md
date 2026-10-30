# Intents — Test Apple Foundation Models before you ship

Canonical website: https://intents-workbench.coryparry.chatgpt.site/

Project home (canonical human page): https://coryparry.dev/projects/intents

## Project

- [Project page](https://coryparry.dev/projects/intents)
- [Cory Parry project guides](https://coryparry.dev/llms.txt)

Intents is a free, open-source native Mac workbench for Apple Foundation Models, made by Cory Parry and released under the MIT licence. Turn prompts into repeatable cases, inspect responses and failures, and compare saved runs after changing instructions, models, or tools.

## Current download and development source

Intents was previously **Foundation Evals**. As checked 30 October 2026, the current published release is **v1.5.2**. Its installer and app use the Intents name.

- [Download Intents 1.5.2 for Apple silicon](https://github.com/coryparrry/Intents/releases/download/v1.5.2/Intents-1.5.2-macOS-arm64.dmg).
- [Release notes and checksums](https://github.com/coryparrry/Intents/releases/tag/v1.5.2).
- [Released interface instructions](https://github.com/coryparrry/Intents/blob/v1.5.2/README.md).
- [Build development source](https://github.com/coryparrry/Intents#build-from-source).

The released workflow includes prompt suites, scoring, traces, saved comparisons, JSON reports, authenticated local MCP access, **Review** and **Batch runs**. Build development source to develop the app or try unshipped changes.

## First use and development workflows

Try “Reply with only the capital of France” and expected text “Paris”. Exact text checks the complete answer; Contains text checks a required phrase. Inspect the response and trace, then change one instruction and compare another saved run. Add failures and repetitions before drawing conclusions.

- [Practical first evaluation and release choice](https://intents-workbench.coryparry.chatgpt.site/getting-started).
- [Current getting-started guide](https://github.com/coryparrry/Intents/blob/main/docs/wiki/Getting-started.md).
- [User guide](https://github.com/coryparrry/Intents/blob/main/docs/wiki/Home.md).
- [Runs and comparisons](https://github.com/coryparrry/Intents/blob/main/docs/wiki/Runs-and-results.md).
- [Review guide](https://github.com/coryparrry/Intents/blob/main/docs/EVAL_REVIEW_GUIDE.md): Human verdicts on saved outputs, confirmed failure patterns, verified regression cases, and held-out judge checks. Review and calibration do not approve a release baseline.
- [Batch guide](https://github.com/coryparrry/Intents/blob/main/docs/PRODUCTION_EVALS_GUIDE.md): Frozen datasets, resumable jobs, captured-output review, and reports retaining missing results and policy scope.
- [Mac App Intent tests (development source)](https://github.com/coryparrry/Intents/blob/main/docs/wiki/Mac-App-Intent-tests.md): Best-effort compiled metadata catalog, explicit JSON inputs and expected results, and a generated AppIntentsTesting runner. Requires a normally installed Mac app, Xcode 27+, macOS 27+, and matching signing teams. Live reliability remains unqualified; no Siri verification.

## Requirements, data, and agent access

macOS 27 or later. The default on-device model needs an Apple Intelligence-capable Apple silicon Mac, Apple Intelligence enabled, and its model downloaded. Source builds and Mac App Intent tests need Xcode 27; ordinary on-device suites do not. Compatible Core AI models and custom HTTP providers have their own requirements. Remote providers and judges use their configured services. Optional Private Cloud Compute uses Apple’s service; tools receive the content needed for their calls.

The built-in MCP server lets coding agents use the evaluation workspace. The released app uses authenticated local access. Follow the guide for your build. [Current MCP guide](https://github.com/coryparrry/Intents/blob/main/docs/wiki/Codex-and-MCP.md). [Swift feature integration](https://github.com/coryparrry/Intents/blob/main/docs/DEVELOPER_SWIFT_INTEGRATION.md) supports registered feature closures on paired apps.

Suites and evidence live on the Mac. Exports can contain prompts, responses, references, and tool content; inspect them before sharing. Optional app-open telemetry is enabled by default and can be disabled in Privacy settings. [Data and troubleshooting](https://github.com/coryparrry/Intents/blob/main/docs/wiki/Data-and-troubleshooting.md).

## Historical website examples

The examples are HTML/CSS browser recreations, not native recordings or live execution. The Conversation behaviour report and Latest preference wins trace use a 17 September 2026 saved run, with 13 measured spans and an 18.39-second workflow. The Mac App Intent JSON contract illustrates unshipped development source. The recorded evaluation predates Review and Batch runs and does not demonstrate today’s complete UI. They do not call models or invoke App Intents. Example scores are not model benchmarks; timings are not performance guarantees.

## Contribute

[Report an issue](https://github.com/coryparrry/Intents/issues) with the release/source commit, macOS/model, a minimal synthetic prompt, scoring rule, expected outcome, and actual response. Review attachments for private data first. Documentation fixes and focused patches are welcome through the [repository](https://github.com/coryparrry/Intents). [MIT licence](https://github.com/coryparrry/Intents/blob/main/LICENSE).

## Install with Homebrew

```sh
brew install --cask coryparrry/tap/intents
```

## Guides & comparisons

- [Intents vs Foundation Evals](https://intents-workbench.coryparry.chatgpt.site/compare/foundation-evals)
- [Intents vs Promptfoo](https://intents-workbench.coryparry.chatgpt.site/compare/promptfoo)
- [Intents vs DeepEval](https://intents-workbench.coryparry.chatgpt.site/compare/deepeval)
- [Intents vs Braintrust](https://intents-workbench.coryparry.chatgpt.site/compare/braintrust)
- [Intents vs Apple’s Evaluations framework](https://intents-workbench.coryparry.chatgpt.site/compare/apple-evaluations)
- [How to evaluate Apple Foundation Models on a Mac before you ship](https://intents-workbench.coryparry.chatgpt.site/guides/evaluate-apple-foundation-models-mac)
- [Install Intents with Homebrew on Apple silicon](https://intents-workbench.coryparry.chatgpt.site/guides/install-intents-homebrew)
- [Connect Codex or Claude Code to Intents over MCP](https://intents-workbench.coryparry.chatgpt.site/guides/intents-mcp-coding-agents)
- [On-device LLM evaluation on macOS 27 (without sending prompts to a vendor SaaS)](https://intents-workbench.coryparry.chatgpt.site/guides/on-device-llm-evaluation-macos)
- [How Intents compares with other LLM evaluation tools](https://intents-workbench.coryparry.chatgpt.site/compare)

## Frequently asked questions

### What is Intents?

Intents is a free, MIT-licensed native Mac workbench for Apple Foundation Models, with suites, scoring, traces, comparisons, Review, Batch runs, and authenticated local MCP.

### How do I install Intents?

Download Intents 1.5.2 for Apple silicon, or run brew install --cask coryparrry/tap/intents. Requires macOS 27 or later.

### Do I need Xcode?

Ordinary on-device suites do not need Xcode. Source builds and development-source Mac App Intent tests require Xcode 27.

### Can I connect a coding agent?

Yes. Open Intents Settings → MCP Connector and choose Connect to Codex, then restart Codex. Other HTTP MCP clients require manual bearer authentication; keep Intents open.

## Apple tools

- [Python SDK comparison](https://intents-workbench.coryparry.chatgpt.site/compare/apple-fm-python-sdk)
- [From fm respond to repeatable evals](https://intents-workbench.coryparry.chatgpt.site/guides/fm-cli-to-repeatable-evals)

### Is Intents related to Apple's App Intents?

No. Intents is an independent evaluation app for Apple Foundation Models. Its development source includes optional Mac App Intent tests, which are unshipped.
