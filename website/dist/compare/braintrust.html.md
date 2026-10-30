# Intents vs Braintrust

Canonical page: https://intents-workbench.coryparry.chatgpt.site/compare/braintrust

## Short answer

Choose Braintrust when shared experiments, production traces, and ongoing scoring across a team are the main requirement. Choose Intents when you want a free native Mac workbench for on-device Apple model evaluations and saved local evidence. They address different operating needs: production observability and collaboration versus a Mac workspace for repeatable evaluation.

## Who should stay with Braintrust?

Stay with Braintrust when your team needs a shared platform for production traces, datasets, experiments, and scoring. Its documented SDKs connect application instrumentation to a broader observability workflow.

## Who should try Intents?

Try Intents for focused Apple model checks on your Mac, without requiring a hosted evaluation account. Saved reports, human Review, and resumable Batch runs support local investigation. They do not provide a hosted production monitoring service.

| Detail | Intents 1.5.2 | Braintrust |
| --- | --- | --- |
| Interface | Native macOS app | Web platform and SDKs |
| Main workflow | Local suites, traces, Review, Batch | Experiments and production observability |
| Language | Swift app; no code for ordinary suites | Multiple SDKs, including Python and TypeScript |
| Apple on-device model setup | Built-in default provider | check |
| Evidence location | Local workspace | Platform storage; check deployment and retention terms |
| Agent access | Authenticated local MCP | MCP support; check scope and authentication |
| Price model | Free, MIT source | Free and paid plans; check current limits |
| Open source | App source under MIT | Open-source SDKs; not a claim that the hosted service is MIT |

## Official sources

[Braintrust homepage](https://www.braintrust.dev/) · [Pricing](https://www.braintrust.dev/pricing) · [Documentation](https://www.braintrust.dev/docs). No price, quota, or retention guarantee is made here; a “check” cell needs direct verification for your deployment.

## Frequently asked questions

### Is Intents a hosted observability service?

No. It is a native Mac evaluation workbench with saved local evidence.

### Can Braintrust handle production traces?

Yes. Its platform documents production tracing and evaluation workflows.

### Is Braintrust entirely open source?

Its SDKs are open source. That does not make the hosted service equivalent to an MIT-licensed desktop application.

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
