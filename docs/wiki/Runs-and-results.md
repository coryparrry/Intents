# Run a suite and understand its results

[Home](Home.md) · [Getting started](Getting-started.md) · [Models and scoring](Models-scoring-and-tools.md)

## Start or cancel a run

1. Open a suite.
2. Select the run destination beside **Run**.
3. For a local run, select **This Mac · built-in evaluator**.
4. For an app run, select a connected device and its registered feature.
5. Select **Run**, or press **⌘↩**.

The local destination uses the suite's model and tools. A connected app uses its registered feature. If that device is unavailable, Intents does not change the destination to This Mac.

The toolbar and suite banner show the number of completed responses. Select **Cancel**, or press **⌘.**, to request cancellation. Each case runs one to five times, according to **Repetitions**.

For a local run, open **Run Details** in the destination menu to read planned response and request counts. If **Run** is disabled, point to it to read its reason. Common causes include missing expected text, an unavailable model, invalid tool settings, or an incomplete file import.

If **Retry Save** appears after a run, the app did not save it. Restore storage access. Then select **Retry Save** before you start another run.

## Read a saved run

1. Select a run in the suite's **Results** page or the sidebar **Runs** list.
2. Select **Workflow trace** or **Report** at the top of the run.

**Workflow trace** shows a timeline for one case and repetition. Expand a span and select it to read its time, metadata, and available input or output. Work can overlap on the timeline. Do not add nested durations together. The trace does not show hidden model reasoning or internal inference timing.

**Report** shows counts, saved responses, scores, explanations, analysis, and the run's settings. Select **All**, **Passed**, **Failed**, or **Issues** to filter samples. Read the response and tool output before you rely on a score.

Select **Export Run as JSON** in the toolbar to save a copy of the run. If a span has a transcript export, that export contains the complete saved transcript. The preview in the app can be shorter. Review prompts, references, responses, tool arguments, and outputs before you share an export.

## Read scores

- **Exact text** compares the whole response after it removes whitespace at both ends.
- **Contains text** looks for literal required text. It ignores letter case and accents.
- **AI rubric** gives each requirement a score from 1 to 4. Every requirement must score at least 3 for a pass.
- **Collect only** saves responses without a text score. JSON field checks can still give a pass or failure.
- An error or an unscored sample is different from a failed check.

The suite's **Results** page shows the latest pass rate and recent scored runs. Pass rates use scored samples. In **Analysis**, latency percentiles exclude errors from the subject request. Read the full report for a canceled or incomplete run. A pass-rate number cannot describe missing evidence.

## Compare a change

1. Run the suite before the change. Run it again after the change.
2. Keep case IDs, scoring, and the relevant model or app environment stable for a direct comparison.
3. Open **Compare**. Select the run to inspect.
4. In **Analysis**, select an earlier run as the baseline.
5. Read compatibility warnings, changes for each case, pass rates, and latency.

Changes to cases, a rubric, or judge settings can limit a comparison.

Under **Compare → Instruction experiments**, select **New Experiment**. Enter a name and proposed instructions. Select **Create experiment**. Then select **Run** on its row to run both versions. Read the results and use **Record decision**.

## Approve a baseline or read release requirements

1. Open a saved run's **Report → Review and approval**.
2. Read the run's responses and checks.
3. If the evidence is suitable, select **Approve as baseline**.

For an AI-assessed run, the selected assessment is part of the approval. The panel can also reassess saved responses with a configured judge. It can record a corrected judgment and preserve the original. Select **Release report** to read the run's release check.

Use **Setup → Scoring → Release requirements** to set limits for errors, pass-rate changes, latency, and critical cases. You can also require an approved baseline. A release report applies these saved limits. It does not replace a review of unclear evidence.

If you edit a suite after its latest run, run it again. Then use the new result for Overview's current status.

## Delete evidence

Use a run's sidebar context menu to delete its results and trace. The suite toolbar's **Start from Scratch** menu offers more reset choices. These choices can reset the suite, clear its runs and traces, or do both. The app asks for confirmation. It cannot undo these actions. Export evidence that you need before you delete it.
