# Review outputs, find failures, and check a judge

Use the suite's **Review** page after saving a run. Its **Samples**, **Patterns**, and **Judge checks** panes work with recorded outputs. Reviewing a sample does not regenerate it or replace its automated score.

For a first run, follow the [getting started guide](wiki/Getting-started.md). For original responses imported from your application, use [Batch runs](wiki/Production-batches.md); its review audit is separate from suite Review.

## Review a saved sample

1. Open a suite and select **Review → Samples**.
2. Select a sample. Read its prompt, recorded output, reference answer, and available context. Expand the recorded evidence when you need instructions, conversation, tools, or trace details.
3. Choose **Passed**, **Failed**, or **Needs more evidence** under **Human verdict**.
4. Explain the observable outcome in **What went right or wrong?**. A review needs a nonempty note.
5. Add up to six comma-separated failure tags, such as `wrong date` or `lost context`.
6. Select **Save review**. You can then select **Reveal AI judgment** to compare your decision with the automated judgment.

AI judgments start hidden so they do not lead your review. **Diverse order** mixes coverage across cases, models, and locales. Search and the **Not reviewed**, **Human failures**, and **Needs more evidence** filters help you choose the next example. This discovery queue does not estimate the production failure rate.

Incomplete subject evidence permits only **Needs more evidence**. Reviews are bound to a digest of their recorded source. If the source changes, the old annotation is marked **Source changed** and cannot support a current failure pattern or promotion. Reinspect the evidence and save a current review.

Unfinished notes are retained as local drafts while you move between samples. Check any storage error before relying on a saved draft or review. Human reviews remain separate from automated scoring and the saved assessment selected for a release report.

## Find a recurring failure

Open **Review → Patterns**. Only current, confirmed human failures with tags appear. Each pattern shows reviewed-example and unique-case counts. Several repetitions can belong to one case; example counts are not independent observations.

Select an example to return to its evidence. Use concrete tags consistently. Describe what failed before deciding whether to change the prompt, tools, model, or scoring rule.

## Turn a failure into a regression case

1. Save a **Failed** review of complete, current evidence.
2. Select **Create regression case**.
3. Supply the correct expected response or a verified reference answer.
4. Select **Create case**, inspect it in **Cases**, and run the suite again.

Promotion preserves the source prompt, conversation, field assertions, and review provenance. The new case uses the current suite's scoring settings. Intents checks the source contract and context before promotion; incompatible or missing evidence blocks it. Review any model, reference, or local-resource change before rerunning.

Use **Compare instruction changes** to open the existing comparison workflow after recording the failure. A new case or changed scoring contract may limit comparison with earlier runs.

## Check a judge against human decisions

1. Save human reviews of both successes and failures.
2. On each reviewed sample, select **Use as judge check → Development** or **Held-out test**.
3. Open **Review → Judge checks** and select a configured **Judge connection**.
4. Select **Run judge checks**. Approve any required external-evidence disclosure before replay.
5. Read the Development and Held-out summaries, including incorrectly accepted failures, incorrectly rejected successes, and unavailable or error examples.

Development examples can help tune a rubric. Reserve Held-out test for examples you have not used to tune it. Moving an example moves every repetition and run of the same case together, preventing a case from appearing in both groups.

Checks replay recorded outputs; they do not execute the app feature again. Summaries are grouped by scoring contract. A missing class has no estimated error rate, and unavailable evidence remains visible. Small held-out sets provide limited evidence. Calibration does not approve a baseline or certify a release.

External judge credentials are bound to the saved connection ID, provider, and exact endpoint. Re-enter an older unbound key, or a key after changing provider or endpoint, in judge settings. A model change alone keeps the endpoint binding. Never add keys to exported evidence.

## Review agent suggestions

An authenticated agent can discover `eval_list_review_samples` and `eval_propose_review` through the [MCP action catalog](MCP_CONTROL_GUIDE.md). Proposals identify the saved run, sample, and source digest. In **Samples**, open the selected sample's **Agent suggestions** disclosure and inspect a proposal before choosing **Use suggestion** or **Reject**. Accepting a suggestion can replace your current note and verdict; read the replacement confirmation.

The advanced MCP controls also support operator-authorized review decisions, regression promotion, and judge checks. An agent's proposed judgment is not a human review merely because a tool returned successfully. Require your authorization for those decisions and read the saved evidence afterward.

## Continue with release evidence

Use [Runs and results](wiki/Runs-and-results.md) for reassessment, selected assessments, suite baseline approval, and release requirements. Use the [production guide](PRODUCTION_EVALS_GUIDE.md) for batch baseline approval and cost, cohort, and critical-source gates. These are separate evidence decisions.
