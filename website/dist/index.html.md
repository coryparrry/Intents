# Intents — Test Apple Foundation Models before you ship

Canonical website: https://intents-workbench.coryparry.chatgpt.site/

Intents is a free, open-source native Mac workbench for Apple Foundation Models, made by Cory Parry and released under the MIT licence. Turn prompts into repeatable cases, inspect responses and failures, and compare saved runs after changing instructions, models, or tools.

## Current download and development source

Intents was previously **Foundation Evals**. As checked 9 October 2026, the current published release is **v1.4.0**, published 4 October 2026. Its installer and app use the Intents name.

- [Download Intents 1.4.0 for Apple silicon](https://github.com/coryparrry/Intents/releases/download/v1.4.0/Intents-1.4.0-macOS-arm64.dmg).
- [Release notes and checksums](https://github.com/coryparrry/Intents/releases/tag/v1.4.0).
- [Released interface instructions](https://github.com/coryparrry/Intents/blob/v1.4.0/README.md).
- [Build development source](https://github.com/coryparrry/Intents#build-from-source).

The released workflow includes prompt suites, scoring, traces, saved comparisons, JSON reports, authenticated local MCP access, **Review**, **Batch runs**, and **Intent Lab (beta)**. Build development source to develop the app or try unshipped changes.

## First use and development workflows

Try “Reply with only the capital of France” and expected text “Paris”. Exact text checks the complete answer; Contains text checks a required phrase. Inspect the response and trace, then change one instruction and compare another saved run. Add failures and repetitions before drawing conclusions.

- [Practical first evaluation and release choice](https://intents-workbench.coryparry.chatgpt.site/getting-started).
- [Current getting-started guide](https://github.com/coryparrry/Intents/blob/main/docs/wiki/Getting-started.md).
- [User guide](https://github.com/coryparrry/Intents/blob/main/docs/wiki/Home.md).
- [Runs and comparisons](https://github.com/coryparrry/Intents/blob/main/docs/wiki/Runs-and-results.md).
- [Review guide](https://github.com/coryparrry/Intents/blob/main/docs/EVAL_REVIEW_GUIDE.md): Human verdicts on saved outputs, confirmed failure patterns, verified regression cases, and held-out judge checks. Review and calibration do not approve a release baseline.
- [Batch guide](https://github.com/coryparrry/Intents/blob/main/docs/PRODUCTION_EVALS_GUIDE.md): Frozen datasets, resumable jobs, captured-output review, and reports retaining missing results and policy scope.
- [Intent Lab setup](https://github.com/coryparrry/Intents/blob/main/docs/wiki/Intent-Lab.md): App-owned support and a signed Xcode UI-test target. Siri uses recognized text on a paired physical iPhone. It does not test microphone recognition. A direct App Intent pass does not prove Siri routing or the app’s observed effect.

## Requirements, data, and agent access

macOS 27 or later. The default on-device model needs an Apple Intelligence-capable Apple silicon Mac, Apple Intelligence enabled, and its model downloaded. Source builds and Intent Lab need Xcode 27; ordinary on-device suites do not. Compatible Core AI models and custom HTTP providers have their own requirements. Remote providers and judges use their configured services. Optional Private Cloud Compute uses Apple’s service; tools receive the content needed for their calls.

The built-in MCP server lets coding agents use the evaluation workspace. The released app uses authenticated local access. Follow the guide for your build. [Current MCP guide](https://github.com/coryparrry/Intents/blob/main/docs/wiki/Codex-and-MCP.md). [Swift feature integration](https://github.com/coryparrry/Intents/blob/main/docs/DEVELOPER_SWIFT_INTEGRATION.md) supports registered feature closures on paired apps.

Suites and evidence live on the Mac. Exports can contain prompts, responses, references, and tool content; inspect them before sharing. Optional app-open telemetry is enabled by default and can be disabled in Privacy settings. [Data and troubleshooting](https://github.com/coryparrry/Intents/blob/main/docs/wiki/Data-and-troubleshooting.md).

## Historical website examples

The examples are HTML/CSS browser recreations, not native recordings or live execution. The Conversation behaviour report and Latest preference wins trace use a 17 September 2026 saved run, with 13 measured spans and an 18.39-second workflow. Intent Lab uses a historical PR54 fixture. These examples predate Review and Batch runs and do not demonstrate today’s complete UI. They do not call models, Siri, or devices. Example scores are not model benchmarks; timings are not performance guarantees.

## Contribute

[Report an issue](https://github.com/coryparrry/Intents/issues) with the release/source commit, macOS/model, a minimal synthetic prompt, scoring rule, expected outcome, and actual response. Review attachments for private data first. Documentation fixes and focused patches are welcome through the [repository](https://github.com/coryparrry/Intents). [MIT licence](https://github.com/coryparrry/Intents/blob/main/LICENSE).
