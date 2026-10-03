# Install Intents and run your first suite

[Home](Home.md) · [Projects and suites](Projects-and-suites.md) · [Runs and results](Runs-and-results.md)

## Before you begin

Intents requires **macOS 27 or later**. The default on-device model also requires a Mac that supports Apple Intelligence. Enable Apple Intelligence and download the model before you use this provider.

Other providers have different requirements. See [Models, scoring, and tools](Models-scoring-and-tools.md). Intent Lab and source builds require Xcode. A normal on-device suite does not require Xcode.

1. Download `Intents.dmg` from the [latest release](https://github.com/coryparrry/Intents/releases/latest).
2. Open the disk image.
3. Drag **Intents** to **Applications**.
4. Eject the disk image.
5. Open **Intents** from Applications.

## Create a small evaluation

1. In **Overview**, select **New Suite**.
2. Enter a suite name. Select **Blank suite** for your own cases, or select a starter pack for editable examples.
3. Select **Create suite**.
4. Open the suite's **Cases** page. Select the first case. Enter a case name and prompt.
5. Select **Add Case** to add another question.
6. Open **Setup → Instructions**. Enter instructions that apply to every case. If each prompt is complete, leave this field empty.
7. Open **Setup → Scoring**. Select **Contains text** for a first literal-text check.
8. Enter **Required text** in each case. Set **Repetitions** to 1.
9. Open **Setup → Model**. Make sure that the selected model is ready.
10. Make sure that the run destination shows **This Mac · built-in evaluator**.
11. Select **Run** in the toolbar. Wait until the response count is complete.
12. Open **Results**, or select the new run under **Runs** in the sidebar.
13. Select **Report** to read each response and score. The run opens on **Workflow trace** by default.

If **Run** is disabled, open **Run Details** from the destination menu. You can also point to **Run** to read the reason.

For practice, use the prompt `Reply with only the capital of France` and the required text `Paris`. **Contains text** passes when the response includes that text. If extra words must cause a failure, use **Exact text**.

## Understand the first result

- **Passed** and **Failed** reflect the selected scoring rule and the saved responses.
- **Collect only** can leave samples without scores. JSON field checks can still give a pass or failure.
- A repetition makes another response to the same case. A small number of repetitions cannot establish statistical certainty.
- A run keeps its suite definition, model, environment, responses, and available traces. Later suite edits do not change that run.
- Overview can show **Changed** after you edit a suite. Run the suite again before you use its status as a current result.

Read [Projects and suites](Projects-and-suites.md) for imports and references. Read [Runs and results](Runs-and-results.md) for traces, comparisons, and baselines.

## Review the output before expanding the test

Open **Review → Samples**, select the saved sample, and record a human verdict and note before revealing its AI judgment. Use **Create regression case** for a confirmed failure with a verified expected answer. Read [Review and judge checks](Review-and-judge-checks.md) for patterns and held-out judge validation.

When you need a larger resumable job or want to label captured application outputs, use [Production batches](Production-batches.md). A small suite pass, a human review, and an approved release baseline are separate evidence decisions.
