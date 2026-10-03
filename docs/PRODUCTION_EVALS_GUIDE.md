# Run production evaluations

[User walkthrough](wiki/Production-batches.md) · [Suite Review](EVAL_REVIEW_GUIDE.md) · [MCP controls](MCP_CONTROL_GUIDE.md)

Batch runs in the sidebar contains Datasets, Jobs, Review, Reports and Workers. The app retains its existing suite editor for instructions, models, tools, conversations and scoring. Freeze the current suite as a dataset, or import a reviewed JSONL file, then create a batch. The execution setup and dataset revision are immutable for that job. Resume starts only remaining requests. Suite changes apply to new jobs.

## Datasets and capture

One UTF-8 JSON object per line. Minimum fields: `id` and `prompt`. Set `sourceID` to a stable pseudonymous source so related examples and repeated trials do not inflate confidence. Include a verified `expected` answer when scoring requires one. Optional `partition` is development, regression or test; defaults to regression. Keep related sources in one partition. Metadata values such as task, locale, language, coverage and sampling become cohorts.

```json
{"id":"event-17","sourceID":"session-4","prompt":"Reply with Friday","expected":"Friday","partition":"regression","metadata":{"task":"format","locale":"en_GB","coverage":"happy-path"}}
```

Production imports require `--production-data --confirm-redacted` or the equivalent app confirmation. This is an operator confirmation, not automatic redaction. Capture is opt-in: the FoundationEvalsDeveloper library exposes `DeveloperProductionCapture`. Supply an application-owned 32-byte HMAC source key, an approved metadata allowlist, a sanitizer and a private local JSONL destination; call `setEnabled(true)` only after your app's consent check. Every text field passes through your sanitizer. The default file retention limit is 50 MB, configurable at initialization. Hitting it stops capture; it never deletes old evidence. Use one source key across your capture sampling frame to group related sources, and rotate only with an explicit new frame. No network upload occurs.

Include `capturedOutput` and `feedback` to review actual outputs without regenerating them. Choose Review captured outputs in Datasets or create a `--captured` job. Outputs start unscored. Reviewers label them; disagreement becomes needs-evidence until the assigned reviewer adjudicates. Held-out examples retain their partition label. Evaluation intentionally runs their input; references are supplied to scoring, and are not added to the subject's prompt.

## CLI and unattended workers

From the repository root, build with `swift build -j 2 --product intents-evals`. The binary is `.build/debug/intents-evals`. Every invocation supplies an absolute store directory. It can share the app's `ProductionEvals` directory when all processes run as a trusted user on storage with coherent file locks and atomic rename. Multiple workers each need a unique ID. Object stores and eventually consistent mounts are unsupported.

```sh
intents-evals import --storage /evals --file /examples.jsonl --name Release --version v1
intents-evals job --storage /evals --dataset CONTENT_REVISION --name Candidate --native --scoring contains --instructions 'Follow the requested format.'
intents-evals worker --storage /evals --worker-id mac-a --native --job JOB_UUID
intents-evals report --storage /evals --job JOB_UUID --output /candidate-report.json
```

The CLI native backend runs Apple's on-device text model and deterministic exact/contains scoring or collection. It requires eligible Apple hardware with Apple Intelligence enabled and the model available. The app's richer native backend retains conversations, structured output, configured tools, supported providers, existing rubric scoring and traces. Run a frozen app-native job unattended using the installed app executable:

```sh
/path/Intents.app/Contents/MacOS/FoundationEvals --production-worker-store /evals --production-worker-id mac-b --production-job JOB_UUID
```

Add `--production-poll` for scheduled and pending jobs. Worker workspace state is isolated in a temporary directory and removed on clean exit. MCP, telemetry and updater startup are disabled. For an external judge, explicitly supply a local app-format `--production-judge-connections /judge-connections.json` plus `--approve-external-judge`. This file contains connection metadata, not keys; credentials resolve from that worker's own Keychain. Unavailable/unapproved judges cannot fall back to another provider. Run without these flags for local judges. A local HTTP tool conservatively makes the job side-effecting; interrupted actions require reconciliation.

For your actual app feature, custom grading, iOS/device harness or service pipeline, use a trusted absolute executable:

```sh
intents-evals job --storage /evals --dataset CONTENT_REVISION --name App-feature --executor /trusted/feature-worker --settings /feature-settings.json --safety sideEffects
intents-evals worker --storage /evals --worker-id device-a --executor /trusted/feature-worker --descriptor /worker.json --poll
```

The executable receives one JSON request on stdin and emits one response on stdout. Request fields include stable requestID, job/dataset digests, slot, repetition, target index, deadline, example and frozen configuration. `example.input` is optional base64 developer-owned typed data. The expected answer is separate; keep it out of subject input. `configuration.executionContext` is base64 JSON with kind `command`, executableDigest and optional base64 settings. Never put credentials in settings; resolve them on the worker. The executable's digest is frozen and checked before every invocation. This does not attest its interpreter, libraries, app build or device; record your actual production build/model in the descriptor and bounded result artifact.

```json
{"requestID":"REQUEST_UUID","outcome":"passed","output":"Friday","latencyMilliseconds":153,"cost":0,"retryable":false}
```

Outcomes: passed, failed, unscored, error, needsEvidence. Optional explanation and base64 artifact retain bounded diagnostic evidence. Maximum output 64 KB, explanation 8 KB, artifact 256 KB; stdout is capped at 512 KB. Custom worker stderr is suppressed. Return `retryable:true` only for a transient error whose replay is safe. Honor cancellation and manage any child processes you spawn. Inference/idempotent jobs retry within limits; sideEffects jobs never automatically replay an uncertain action. Command workers default to sideEffects. Direct CLI commands never execute shell strings.

Descriptor JSON contains id, name, platform, operatingSystem, hardware, locale, model and lastSeen (Unix milliseconds). OS/model/locale values are exact filters. Use `--targets /targets.json` containing an array of target objects to repeat each example across a matrix. These are worker-reported labels, not hardware attestation. Deploying workers, eligible iOS harnesses and trusted filesystem access remains your team's responsibility.

## Gates, budgets and CI

`report` returns 0 for passing policy, 10 for quality/regression failure, 20 for incomplete/uncertain evidence and 30 for execution failure. Never treat successful worker launch as a release pass. Missing, unscored, cancelled or uncertain results block qualification. Default quality policy requires every scored response to pass and permits zero execution errors. App batches also copy the suite's critical cases, error/average-latency limits and baseline requirements. Trial counts and distinct-source confidence are shown separately; curated/targeted datasets never claim production prevalence.

Use `--policy /policy.json` for the full Codable policy contract (see ProductionGatePolicy): minimumPassRate, maximumErrors, optional maximumAverageMilliseconds/maximumP95Milliseconds, maximumPassRateRegression, criticalSourceIDs, requiredCohorts, cohortMinimumPassRates and requireBaseline. Thresholds are fractions 0–1. Cohort threshold keys look like `locale=fr_FR`. A required absent cohort cannot pass. `--baseline JOB_UUID` requires identical dataset, scoring, repetitions and targets. Reports show overall and cohort changes; scheduling creates fresh candidate jobs against the frozen baseline. Statistical intervals describe distinct-source outcomes; a point-estimate gate is not a statistical non-inferiority test.

Use `--timeout`, `--attempts`, `--budget-seconds` and optional `--max-cost` with `--cost-per-attempt` to bound admission. Cost caps use a declared per-attempt upper allowance and provider-reported costs; they are not a billing guarantee. Unknown charges retain reservations and block qualification. Interrupted action reconciliation requires assigned reviewer identity, evidence and verified outstanding cost when known. The audit is published before ledger settlement and can recover it after interruption.

```sh
intents-evals schedule --storage /evals --job JOB_UUID --interval 86400 --runs 30
intents-evals worker --storage /evals --worker-id mac-a --native --poll
```

Scheduling requires a live polling worker or explicit `tick`. Nothing installs a daemon or provisions machines. In CI, run the matching worker then run report and propagate its exit code. Shared filesystem coordination is trusted local collaboration, with append-only reviewer attribution; it does not authenticate names or provide hosted permissions.

Repeat batch or `clone --job JOB_UUID --name NAME` creates a fresh job with the same frozen setup. Pause/cancel retains checkpoints. Cancellation is permanent for the job; create another job to repeat the experiment. `export --job JOB_UUID --output /new-evidence-directory` saves dataset, job/chunks, report and complete review history. Exports can include sensitive source content: keep them private until separately reviewed. Export does not delete evidence. Capture file limits and bounded dataset/job sizes provide retention boundaries; permanent deletion is an explicit operator task.

## Baseline approval and critical cases

A policy requiring an approved baseline now requires an explicit approval of the exact saved job and evidence. Use **Approve as baseline…** in Reports, the on-demand MCP action `eval_production_baseline_approve`, or:

```sh
intents-evals approve-baseline --storage STORE --job UUID --revision JOB_REVISION --evidence EVIDENCE_REVISION --note "Reviewed saved results" --confirm
```

Read both revisions from the report. Only complete, scored, eligible evidence can be approved. A first baseline can be approved without its own predecessor baseline. Cancellation is permanent; clone the job to run again. Paused or cancelled baselines cannot qualify another job. Reviews and control changes invalidate prior approval, even if pause is later reversed. Approval history is included in evidence exports.

Critical suite case UUIDs map to imported example IDs, source IDs, or the explicit JSONL field `metadata.suiteCaseID`. One case may cover multiple sources; each must pass every trial. Job creation rejects missing mappings before publishing a job.

Reports hold the shared store transaction while reading costs, results, reviews and baseline evidence. This gives a coherent report while briefly blocking worker writes. The dataset reader verifies dataset files once per report; corruption checks remain active.

## Saved external judge credentials

API keys are bound in Keychain to the saved connection UUID, provider and exact endpoint URL. Imported or frozen metadata cannot redirect an existing credential. Earlier unbound keys are preserved but require explicit re-entry in judge settings before use. Endpoint or provider changes also require re-entry; model changes retain the endpoint binding. Do not put credentials in worker requests or exported evidence.

## Check a local CLI build

```sh
swift test --package-path Packages/ProductionEvals -j 2
swift build --product intents-evals -j 2
python3 script/test_production_evals.py .build/debug/intents-evals
```

The package and process integration checks use fixtures and isolated storage. They do not certify a signed installer, customer traffic, physical devices, or live external judges. Report exit codes are 0 for qualifying evidence, 10 for policy failure, 20 for incomplete evidence, and 30 for execution errors.
