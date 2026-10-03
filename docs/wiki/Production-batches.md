# Run and review production batches

[Home](Home.md) · [Runs and results](Runs-and-results.md) · [Codex and MCP](Codex-and-MCP.md)

Open **Batch runs** in the sidebar for larger, resumable jobs or review of captured application outputs. This workspace has **Datasets**, **Jobs**, **Review**, **Reports**, and **Workers**. Ordinary suite runs and suite **Review** remain separate.

## Create a batch

1. Configure the selected suite's instructions, model, tools, and scoring.
2. In **Datasets**, freeze the current suite or import a reviewed UTF-8 JSONL file. Confirm redaction when importing production data.
3. Give examples stable IDs and group related examples with a pseudonymous `sourceID`. Include verified expected answers when scoring needs them.
4. In **Jobs**, create a batch with its dataset, repetitions, target labels, limits, and release requirements.
5. Start it on a matching Mac. Read saved progress and worker provenance. Pause and resume to continue remaining requests.
6. Open **Reports** for pass rates, cohorts, distinct-source confidence, cost, latency, and gate failures.

The dataset and execution configuration are frozen for the job. Later suite edits apply to new jobs. **Repeat batch** creates a fresh job from the frozen setup. Cancellation is permanent for the selected job and retains checkpoints.

The app's native worker can retain conversations, structured output, configured tools, supported providers, rubric scoring, and traces. The standalone CLI's native worker supports on-device text with exact/contains scoring or collection. Command workers execute a developer-owned trusted executable. See the [full production guide](https://github.com/coryparrry/Intents/blob/main/docs/PRODUCTION_EVALS_GUIDE.md) for each backend's setup.

## Review original outputs

Include `capturedOutput` and optional `feedback` in JSONL, then choose **Review captured outputs** in Datasets. These outputs are not regenerated. Use **Review** to assign and label results. Disagreement remains uncertain until adjudicated. Reconcile interrupted actions only after verifying their saved state and outstanding cost.

Capture is opt-in and uses an application-owned sanitizer. An import's redaction confirmation is your review of the data; it does not redact the file automatically. Keep exports private until you have checked prompts, responses, metadata, traces, and artifacts.

## Qualify a candidate

A required baseline needs explicit approval of complete, eligible, current saved evidence. In **Reports**, read the baseline and select **Approve as baseline…** with a review note. Changes to results, reviews, or controls invalidate that approval. Paused or cancelled baselines cannot qualify another job.

If the suite has critical cases, imported examples must map them through the example ID, source ID, or `metadata.suiteCaseID`. Missing mappings block job creation. Every mapped critical source must pass every trial.

Missing, unscored, uncertain, or required cost/latency evidence prevents qualification. Cohort and critical-source gates apply the frozen policy. Distinct-source confidence describes this dataset; curated examples do not establish a production failure rate.

## Workers and schedules

The Workers pane records worker labels and schedules. A schedule needs the app or a polling worker to tick and execute jobs; it does not install a daemon or provision machines. Shared storage requires trusted users, coherent file locks, and atomic rename. Worker labels are reported provenance, not hardware attestation.

The [CLI, worker, baseline, and credential reference](https://github.com/coryparrry/Intents/blob/main/docs/PRODUCTION_EVALS_GUIDE.md) includes unattended commands and report exit codes. The [MCP guide](https://github.com/coryparrry/Intents/blob/main/docs/MCP_CONTROL_GUIDE.md) covers authenticated batch controls and safe retries.
