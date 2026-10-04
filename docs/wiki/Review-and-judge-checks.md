# Review outputs and check a judge

[Home](Home.md) · [Runs and results](Runs-and-results.md) · [Models and scoring](Models-scoring-and-tools.md)

Open a suite's **Review** page after saving a run. It has three panes:

| Pane | Use it to… |
|---|---|
| **Samples** | Read recorded outputs with the AI judgment initially hidden; save a human verdict, note, and failure tags. |
| **Patterns** | Find recurring tags among current, confirmed failures and open their source evidence. |
| **Judge checks** | Replay a configured judge against human-reviewed Development and Held-out examples. |

## Start with one sample

1. Open **Review → Samples** and select an output.
2. Read the prompt, response, reference, and recorded context.
3. Choose **Passed**, **Failed**, or **Needs more evidence**. Write a note; optionally add up to six failure tags.
4. Select **Save review**, then **Reveal AI judgment** if you want to compare decisions.
5. For a confirmed failure, select **Create regression case** and supply the correct expected answer. Inspect the new case and rerun it.

Incomplete evidence cannot receive a human pass or failure. A review marked **Source changed** must be reviewed again. Draft notes are retained locally; read storage errors before leaving unfinished work.

## Keep judge tuning and validation separate

Use **Use as judge check** on saved human successes and failures. Put tuning examples in **Development** and untouched validation examples in **Held-out test**. Every repetition and run of a case moves together. Select a judge and **Run judge checks** to replay recorded outputs, subject to external-evidence approval.

Read false acceptance, false rejection, and unavailable counts for each scoring contract. These checks do not rerun the app feature, estimate production prevalence, or approve a release baseline.

The [complete Review guide](https://github.com/coryparrry/Intents/blob/main/docs/EVAL_REVIEW_GUIDE.md) covers patterns, promotion checks, drafts, agent suggestions, and credential changes. [Batch runs](Production-batches.md) has a separate audit for imported original responses.
