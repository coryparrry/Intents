# How to evaluate Apple Foundation Models on a Mac before you ship

Canonical page: https://intents-workbench.coryparry.chatgpt.site/guides/evaluate-apple-foundation-models-mac

## Short answer

Install Intents 1.5.2 on an Apple silicon Mac running macOS 27 or later, with Apple Intelligence enabled and its model downloaded. Create one suite with an explicit scoring rule, run it, and read the saved response and trace. Expand with failure cases and repetitions before treating the result as evidence for a release.

## Prepare the Mac

Install the released app with the download or Homebrew below. Ordinary on-device suites do not need Xcode. In **Setup → Model**, confirm the default Apple model is ready before running a case. Model download and readiness are prerequisites, not something this website can verify.

## Create one literal-text check

1. In **Model evaluations**, select **New Suite**, choose **Blank suite**, enter a name, and select **Create suite**.
2. Open **Cases** and select the first case. Name it “Capital answer” and enter `Reply with only the capital of France`.
3. Open **Setup → Scoring** and select **Contains text**. Enter `Paris` as the case’s **Required text**; set **Repetitions** to 1. Use **Exact text** if additional words must fail.
4. Confirm **Setup → Model** is ready and the destination shows **This Mac · built-in evaluator**. Select **Run**.
5. Select the saved run. Read **Report** and **Workflow trace**. If Run is disabled, open **Run Details** from the destination menu for the reason.

## Make the test useful

A score says whether an output met your chosen rule; it does not prove the response is correct in every context. Inspect the actual answer. Add an ambiguous request, a formatting edge case, and a changed-preference case that reflects your product. Change one instruction, rerun the same cases, and compare saved runs.

Use **Review → Samples** to record a human verdict before revealing the AI judgment. A confirmed failure with a verified answer can become a regression case. Use repetitions to explore variability; a small sample does not establish statistical confidence.

## Keep the evidence boundary clear

Saved comparisons, JSON reports, Review, and Batch runs are released features. Mac App Intent JSON checks described on this site remain development-source workflows requiring a signed AppIntentsTesting runner; live reliability is unqualified and microphone Siri is not verified. The homepage demos are historical browser recreations, not this evaluation.

Follow the [released first-suite guide](https://github.com/coryparrry/Intents/blob/v1.5.2/docs/wiki/Getting-started.md) and [Review guide](https://github.com/coryparrry/Intents/blob/v1.5.2/docs/EVAL_REVIEW_GUIDE.md). Compare the workbench with [Apple Evaluations](/compare/apple-evaluations) if your evaluation belongs in an app test target.

## Try Intents 1.5.2

[Download for macOS · v1.5.2](https://github.com/coryparrry/Intents/releases/download/v1.5.2/Intents-1.5.2-macOS-arm64.dmg) · [Getting started](/getting-started)

```sh
brew install --cask coryparrry/tap/intents
```

Free, MIT licensed, macOS 27+, Apple silicon. Enable Apple Intelligence and download its model for the default on-device provider. Ordinary model suites do not require Xcode.

## Sources and corrections

Facts checked 26 October 2026. [Intents release](https://github.com/coryparrry/Intents/releases/tag/v1.5.2) · [User guide](https://github.com/coryparrry/Intents/blob/v1.5.2/docs/wiki/Home.md) · [MCP guide](https://github.com/coryparrry/Intents/blob/v1.5.2/docs/wiki/Codex-and-MCP.md). [Report a correction](https://github.com/coryparrry/Intents/issues).

[All comparisons](/compare) · [Evaluate on a Mac](/guides/evaluate-apple-foundation-models-mac) · [Connect an agent](/guides/intents-mcp-coding-agents)
