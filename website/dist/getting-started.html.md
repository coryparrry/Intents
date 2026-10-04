# Get started with Intents

Canonical page: https://intents-workbench.coryparry.chatgpt.site/getting-started

Start with a test you can explain.

Intents is a free, open-source Mac workbench for Apple Foundation Models. Start with one prompt, a concrete expectation, and a saved response. Then add cases that expose failures.

## Choose a build

### Released download: Foundation Evals 1.3.0

Published 20 September 2026. Intents was previously named Foundation Evals, so this installer and its app still use the old name. It supports prompt suites, scoring, traces, saved comparisons, JSON exports, and a local MCP server.

[Download the Apple silicon disk image](https://github.com/coryparrry/Intents/releases/download/v1.3.0/Foundation-Evals-1.3.0-macOS-arm64.dmg) · [Release notes and checksums](https://github.com/coryparrry/Intents/releases/tag/v1.3.0)

Open `Foundation-Evals-1.3.0-macOS-arm64.dmg`, drag Foundation Evals to Applications, eject the disk image, and open the app. Follow the [v1.3.0 instructions](https://github.com/coryparrry/Intents/blob/v1.3.0/README.md#run-your-first-evaluation) for this interface.

### Development source: Intents

Current main adds the newer interface, suite Review, Batch runs, and Intent Lab (beta). These are not included in the v1.3.0 installer. The 1.4.0 release is pending; check [published releases](https://github.com/coryparrry/Intents/releases) for any later download.

With Xcode 27 and its command-line tools selected, clone the repository and run the project’s build script:

```sh
git clone https://github.com/coryparrry/Intents.git
cd Intents
./script/build_and_run.sh
```

The script builds and opens `dist/Intents.app`. Read the [source build instructions](https://github.com/coryparrry/Intents#build-from-source) and [current user guide](https://github.com/coryparrry/Intents/blob/main/docs/wiki/Home.md).

## Check model readiness

Requires macOS 27 or later. The default on-device provider needs an Apple Intelligence–capable Apple silicon Mac, Apple Intelligence enabled, and its model downloaded. Ordinary on-device suites do not need Xcode. Source builds and Intent Lab require Xcode 27.

Compatible Core AI models and custom HTTP providers have their own requirements. Remote providers and judges use their configured services. Optional Private Cloud Compute uses Apple’s service; tools can disclose the content needed for their calls. See [data and troubleshooting](https://github.com/coryparrry/Intents/blob/main/docs/wiki/Data-and-troubleshooting.md).

## Run your first case

In v1.3.0, start in **Suite Editor**. In development source, create a suite in **Overview**, then open **Cases** and **Setup → Scoring**.

- Name the case “Capital answer”. Enter the prompt `Reply with only the capital of France` and expected text `Paris`.

- Choose **Exact text** to check the whole answer. Choose **Contains text** if extra words are allowed. Start with one repetition and no tools.

- Check that the model is ready, run the suite, and open its saved report and workflow trace. The [current getting-started guide](https://github.com/coryparrry/Intents/blob/main/docs/wiki/Getting-started.md) explains source controls.

## Read and compare results

Inspect the actual answer alongside the score. A pass means the response met your chosen scoring rule. Traces help explain measured stages and tool activity. Change one instruction, rerun the same cases, and compare the saved runs.

Add a formatting failure, an ambiguous request, and a changed-preference case. Use repetitions to inspect variation. Small examples are not model benchmarks and do not establish statistical certainty. In source, [Review](https://github.com/coryparrry/Intents/blob/main/docs/EVAL_REVIEW_GUIDE.md) records human verdicts and verified regression cases; [Batch runs](https://github.com/coryparrry/Intents/blob/main/docs/PRODUCTION_EVALS_GUIDE.md) retains frozen datasets and resumable jobs.

## Testing your app’s actions

[Intent Lab](https://github.com/coryparrry/Intents/blob/main/docs/wiki/Intent-Lab.md) needs app-owned test support and a signed UI-test target. Siri scenarios supply recognized text to a paired physical iPhone; they do not test microphone recognition. A direct App Intent pass does not prove Siri routing or the app’s observed effect. Read the separate action receipts and state checks.

## Help improve a failure case

When [reporting an issue](https://github.com/coryparrry/Intents/issues), include your release or source commit, macOS and model, a minimal synthetic prompt, scoring rule, expected result, and actual response. Review exports for private content before attaching them. A reproducible case, documentation correction, or focused patch helps others test the same behavior. The source uses the [MIT licence](https://github.com/coryparrry/Intents/blob/main/LICENSE).

Version facts checked 4 October 2026. The homepage’s HTML/CSS examples use a 17 September saved run and historical PR54 fixture, predating Review and Batch runs. They are browser recreations, not live model or Siri execution. Example scores are not model benchmarks.

[Return to the workbench showcase](/) · [Product overview in Markdown](/index.html.md)
