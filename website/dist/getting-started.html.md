# Get started with Intents

Canonical page: https://intents-workbench.coryparry.chatgpt.site/getting-started

Start with a test you can explain.

## Short answer

Intents is a free, open-source Mac workbench for Apple Foundation Models. Start with one prompt, a concrete expectation, and a saved response. Then add cases that expose failures.

## Choose a build

### Install Intents 1.6.0

Use the signed download on an Apple silicon Mac with macOS 27 or later. Intents was previously named Foundation Evals.

[Download for macOS · v1.6.0](https://github.com/coryparrry/Intents/releases/download/v1.6.0/Intents-1.6.0-macOS-arm64.dmg) · [Release notes and checksums](https://github.com/coryparrry/Intents/releases/tag/v1.6.0)

```sh
brew install --cask coryparrry/tap/intents
```

Open `Intents-1.6.0-macOS-arm64.dmg`, drag Intents to Applications, eject the disk image, and open the app. Follow the [v1.6.0 instructions](https://github.com/coryparrry/Intents/blob/v1.6.0/README.md#run-your-first-evaluation) for this interface.

### Development source: Intents

Build from source to develop the app or try upcoming changes.

With Xcode 27 and its command-line tools selected, clone the repository and run the project’s build script:

```sh
git clone https://github.com/coryparrry/Intents.git
cd Intents
./script/build_and_run.sh
```

The script builds and opens `dist/Intents.app`. Read the [source build instructions](https://github.com/coryparrry/Intents#build-from-source) and [current user guide](https://github.com/coryparrry/Intents/blob/main/docs/wiki/Home.md).

## Check model readiness

Requires macOS 27 or later. The default on-device provider needs an Apple Intelligence–capable Apple silicon Mac, Apple Intelligence enabled, and its model downloaded. Ordinary on-device suites do not need Xcode. Source builds and Mac App Intent tests require Xcode 27.

Compatible Core AI models and custom HTTP providers have their own requirements. Remote providers and judges use their configured services. Optional Private Cloud Compute uses Apple’s service; tools can disclose the content needed for their calls. See [data and troubleshooting](https://github.com/coryparrry/Intents/blob/main/docs/wiki/Data-and-troubleshooting.md).

## Run your first case

Select **New Suite** at the bottom of the sidebar. Choose **Blank suite**, enter a name, and select **Create suite**. Open **Cases** and **Setup → Scoring**.

- Name the case “Capital answer”. Enter the prompt `Reply with only the capital of France` and expected text `Paris`.

- Choose **Exact text** to check the whole answer. Choose **Contains text** if extra words are allowed. Start with one repetition and no tools.

- Check that the model is ready, run the suite, and open its saved report and workflow trace. The [current getting-started guide](https://github.com/coryparrry/Intents/blob/main/docs/wiki/Getting-started.md) explains the app controls.

## Read and compare results

Inspect the actual answer alongside the score. A pass means the response met your chosen scoring rule. Traces help explain measured stages and tool activity. Change one instruction, rerun the same cases, and compare the saved runs.

Add a formatting failure, an ambiguous request, and a changed-preference case. Use repetitions to inspect variation. Small examples are not model benchmarks and do not establish statistical certainty. In the released app, [Review](https://github.com/coryparrry/Intents/blob/main/docs/EVAL_REVIEW_GUIDE.md) records human verdicts and verified regression cases; [Batch runs](https://github.com/coryparrry/Intents/blob/main/docs/PRODUCTION_EVALS_GUIDE.md) retains frozen datasets and resumable jobs.

## Try the 1.6.0 evaluation workflows

- Choose **New Suite → From document…** to draft questions, reference answers, and scoring criteria from a text-based PDF, Markdown, or UTF-8 text file. Review the source evidence and accept drafts before creating the suite. Generation uses Apple’s on-device model and a configured semantic judge you authorize to receive the document. [Document suite guide](https://github.com/coryparrry/Intents/blob/v1.6.0/docs/wiki/Document-suites.md).
- Choose **Setup → Instructions → Improve instructions** to compare two suggested sets of instructions on Practice cases. If a suggestion improves the Practice pass rate, Intents checks the best one on reserved Final check cases. You choose whether to apply it. [Instruction comparison guide](https://github.com/coryparrry/Intents/blob/v1.6.0/docs/instruction-improvement.md).

## Test your Mac app’s actions

Open **App Intent Testing** in the sidebar, choose a built macOS app, and select an action. Supply its JSON inputs and, optionally, the expected return value. The generated AppIntentsTesting runner needs Xcode 27 or later, XcodeGen, a normally installed and registered app, and matching development-team signatures. The check calls the action directly. [Mac App Intent setup and qualification](https://github.com/coryparrry/Intents/blob/v1.6.0/docs/wiki/Mac-App-Intent-tests.md).

## Help improve a failure case

When [reporting an issue](https://github.com/coryparrry/Intents/issues), include your release or source commit, macOS and model, a minimal synthetic prompt, scoring rule, expected result, and actual response. Review exports for private content before attaching them. A reproducible case, documentation correction, or focused patch helps others test the same behavior. The source uses the [MIT licence](https://github.com/coryparrry/Intents/blob/main/LICENSE).

Release details checked 6 November 2026. The homepage shows a recorded 17 September evaluation and a sample Mac App Intent JSON contract. Both are browser examples. The scores describe the recorded cases.

[Return to the workbench showcase](/) · [Product overview in Markdown](/index.html.md)

## Guides for your next step

- [How to evaluate Apple Foundation Models on a Mac before you ship](/guides/evaluate-apple-foundation-models-mac)
- [Install Intents with Homebrew on Apple silicon](/guides/install-intents-homebrew)
- [Connect Codex or Claude Code to Intents over MCP](/guides/intents-mcp-coding-agents)
- [On-device LLM evaluation on macOS 27 (without sending prompts to a vendor SaaS)](/guides/on-device-llm-evaluation-macos)

[Compare evaluation tools](/compare)
