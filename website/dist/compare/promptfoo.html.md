# Intents vs Promptfoo

Canonical page: https://intents-workbench.coryparry.chatgpt.site/compare/promptfoo

## Short answer

Choose Intents for a native Mac workbench focused on Apple Foundation Models, with saved responses, traces, Review, Batch runs, and local MCP. Choose Promptfoo when declarative evaluation matrices, a CLI, CI integration, and red teaming fit your workflow. Both can run evaluations locally; the configured model and judge determine where content goes.

## Who should stay with Promptfoo?

Stay with Promptfoo if your team already versions evaluation configuration with application code or needs automated red teaming. Its CLI, library, browser viewer, and CI integrations support a different working style from a native Mac app.

## Who should try Intents?

Try Intents when you want to author small Apple model suites, read saved responses and traces, and review results in a Mac interface. You can retain Promptfoo for your existing CI checks.

| Detail | Intents 1.5.2 | Promptfoo |
| --- | --- | --- |
| Interface | Native macOS app | CLI, library, browser viewer |
| Definitions | Suites in a Mac workspace | Declarative YAML configuration |
| Local execution | Default Apple on-device provider | Local runner; selected providers may be remote |
| CI and security testing | Saved evidence and agent controls | CI integration and automated red teaming |
| Apple Foundation Models adapter | Built in | check |
| Agent integration | Authenticated local MCP | MCP capabilities; check exact setup |
| Price model | Free app, MIT source | Open-source core; commercial options, check current terms |

## Official sources

[Promptfoo introduction](https://www.promptfoo.dev/docs/intro/) · [Promptfoo evaluation configuration](https://www.promptfoo.dev/docs/configuration/guide/) · [Promptfoo homepage](https://www.promptfoo.dev/). A “check” cell means this comparison does not establish that capability or term.

## Frequently asked questions

### Is Promptfoo cloud-only?

No. Its evaluation runner can run locally. Providers and judges may still call remote services.

### Does Intents replace Promptfoo red teaming?

Intents is a Mac evaluation workbench. This comparison does not claim equivalent automated red-team coverage.

### Can I use both?

Yes. Use each for its own workflow and compare results only when cases, models, scoring rules, and environments match.

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
