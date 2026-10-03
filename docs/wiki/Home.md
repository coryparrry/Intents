# Intents user guide

Intents is a macOS app for testing Apple Foundation Models and features in your own app. A **suite** contains repeatable test cases. You can run a suite on this Mac or through a connected app. Intents saves each response and its evidence. Suite **Review** adds human labels, failure patterns, regression cases, and judge checks. **Batch runs** handles frozen datasets, resumable jobs, and review of captured outputs.

**Intent Lab (Beta)** uses separate checks for App Intent actions and Siri results on a supported iPhone.

## Start here

1. [Install Intents and run your first suite](Getting-started.md)
2. [Organize projects, suites, cases, and reference files](Projects-and-suites.md)
3. [Read results, traces, comparisons, and release checks](Runs-and-results.md)

## Choose your task

| I want to… | Read… |
|---|---|
| Change the model, scoring, tools, structured output, or performance settings | [Models, scoring, and tools](Models-scoring-and-tools.md) |
| Run checks on a feature in my iPhone, iPad, or Mac app | [Connect an app feature runner](App-feature-runners.md) |
| Run an App Intent or Siri check | [Use Intent Lab](Intent-Lab.md) |
| Review saved outputs, find recurring failures, or check a judge | [Review and judge checks](Review-and-judge-checks.md) |
| Run larger jobs or review original production outputs | [Production batches](Production-batches.md) |
| Validate an exported Intent Lab execution without the app | [Offline Intent Lab evidence](Intent-Evidence.md) |
| Let Codex manage the shared workspace and read saved evidence | [Connect Codex through MCP](Codex-and-MCP.md) |
| Find saved data or solve a setup problem | [Data, privacy, and troubleshooting](Data-and-troubleshooting.md) |

## Three types of evidence

| Test | What runs | What a pass means |
|---|---|---|
| Suite on **This Mac** | The selected model uses the suite's prompts, settings, references, and tools. | The saved responses passed the selected scoring method. |
| Suite on a **connected app** | A feature that the app registered with Intents. | The app's feature returned responses that passed the suite's checks. |
| **Intent Lab** | The app's UI-test support runs separate App Intent and optional Siri checks. | The required parts of the scenario passed. A direct App Intent pass does not prove Siri behavior. |

Intents saves runs and reports on this Mac. A score, an Xcode test result, and a release check measure different things. Read the saved evidence before you approve a baseline or release a change. Human review and judge calibration do not themselves approve a baseline. Batch reports apply the frozen dataset and job policy; their source-grouped confidence does not establish real-world prevalence for curated data.

This guide describes the current app source. Some controls require a model, judge, app runner, Xcode, or physical device.
