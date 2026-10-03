# Production eval worklog

Objective: implement the eight requirements in the production eval spec, preserve the existing UI, and deliver independently of the managed intents stack.

Base: eval review commit 8d24fb5f1502481641c029d00722a17ac037af66. Managed worktree production-evals; branch codex/production-eval-workspace. Original dirty checkout preserved. Merge after the existing stack and PR #67; no gh-stack membership.

Research: extend the existing suite runner, scoring, trace, release policy and review workflows. Use representative source-grouped datasets, explicit held-out partitions, bounded execution and separate fixture/device evidence.

Implemented: immutable indexed datasets; chunk leases/checkpoints; bounded retries, time and cost; crash-safe cost journal; opt-in sanitized capture; original-output review; assignments/adjudication/audit; coherent exports; cohorts/baselines/gates; CLI and native workers; scheduling; visible Batch runs sidebar/panes.

Verification: full 18-test package suite passed, including 10,000 fixture responses and restart/resume without duplicates. CLI integration passed 39 real-process assertions. Final capture fix passed two focused tests; public SDK and standalone CLI build passed. Native app build and ad-hoc signature verification passed.

Independent review: separate core/execution/privacy and native/UI reviews. Material findings fixed and rechecked; final reviewers reported no remaining material issues. One race in capture creation now uses non-truncating atomic open before locking.

Observed native flow: import preview/redaction gate, prompt/reference context, attributed review, passing and incomplete reports, saved trace, Repeat batch and worker provenance. Final pane navigation resets scrolling; captured-output latency is unavailable. Screenshots inspected using the app's existing layout/components/colors.

Live evidence: one GUI and one unattended on-device/rubric synthetic check passed on this Mac. Unattended exit 0; desktop workspace unchanged; temporary worker directory removed. This does not qualify physical device fleets or customer traffic.

Retained failure lessons: delayed process stdout exposed cached URL file-size reads; worker monitoring now uses fresh file attributes and the CLI fixture deliberately delays output. A prior modal kept an older app process alive; final UI checks verified launch time/path, closed the sheet before quitting, and rechecked the exact test process. Build/test logs retain the observed failures and subsequent passes outside the checkout.

Completion: spec, guide, verification record and focused standalone draft PR. Test apps closed. No hosted fleet, daemon, cloud permissions or release silently provisioned.
