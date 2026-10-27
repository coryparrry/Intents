# Intents vs Foundation Evals

Canonical page: https://intents-workbench.coryparry.chatgpt.site/compare/foundation-evals

## Short answer

Intents and Foundation Evals are the same open-source project. Intents is the current name; Foundation Evals is the earlier name you may see in old downloads, source paths, or screenshots. Install Intents 1.5.2 for the current Mac workbench, including suites, traces, Review, Batch runs, and authenticated local MCP.

## What changed with the name?

Intents was previously Foundation Evals. From the 1.4 release, the installer and application use Intents. The name covers a workbench that has grown beyond prompt experiments into saved evidence, review, and agent workflows. Earlier Foundation Evals installers are historical; they are not the recommended download.

| Detail | Intents | Foundation Evals |
| --- | --- | --- |
| Project | Current name | Earlier name of the same project |
| Recommended installer | Intents 1.5.2 | Historical downloads |
| Source licence | MIT | Same project history |
| Website examples | Historical browser recreations | May show earlier labels |

## Who should keep an older build?

Keep a known older environment when reproducing an old result. Record its exact version and review its instructions. Do not interpret an older screenshot as the current interface.

## Who should install Intents?

Choose Intents for new evaluations. The current release includes Review and Batch runs; the getting-started guide describes the released interface. Use the same project’s release history to trace changes rather than treating the names as competing tools.

## Frequently asked questions

### Are Intents and Foundation Evals separate apps?

They are names from the same project history. Intents is the current product name.

### Which download should I use?

Use Intents 1.5.2 for Apple silicon, or install coryparrry/tap/intents with Homebrew.

### Are the website demos current model runs?

No. They are historical HTML recreations and an illustrative development-source contract, not live model runs or benchmarks.

## Try Intents 1.5.2

[Download for macOS · v1.5.2](https://github.com/coryparrry/Intents/releases/download/v1.5.2/Intents-1.5.2-macOS-arm64.dmg) · [Getting started](/getting-started)

```sh
brew install --cask coryparrry/tap/intents
```

Free, MIT licensed, macOS 27+, Apple silicon. Enable Apple Intelligence and download its model for the default on-device provider. Ordinary model suites do not require Xcode.

## Sources and corrections

Facts checked 26 October 2026. [Intents release](https://github.com/coryparrry/Intents/releases/tag/v1.5.2) · [User guide](https://github.com/coryparrry/Intents/blob/v1.5.2/docs/wiki/Home.md) · [MCP guide](https://github.com/coryparrry/Intents/blob/v1.5.2/docs/wiki/Codex-and-MCP.md). [Report a correction](https://github.com/coryparrry/Intents/issues).

[All comparisons](/compare) · [Evaluate on a Mac](/guides/evaluate-apple-foundation-models-mac) · [Connect an agent](/guides/intents-mcp-coding-agents)
