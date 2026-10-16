---
name: evaluation-traces
description: Inspect actual app evaluation runs, workflow spans, Apple transcripts, usage, scoring, tools, repeatability and release evidence inside Codex.
---

Locate saved evidence with `eval_list_runs` and `eval_get_run`. Runs preserve
the suite snapshot/revision, flat compatibility results, raw appRun and raw
appSample evidence. Use the workspace Workflow trace or Report inspector.

Inspect recorded workflow parent/span IDs, offsets/durations, transcript,
subject/judge usage, tool calls, field checks, refusal and error evidence.
Transcript capture may be disabled. Missing evidence remains missing; never
synthesize spans or infer token throughput without real token counts.
App scores are1–4. Selected assessments may project current scores, while the
original sample and separate human correction records remain preserved.

Use `eval_analyze_run`/`eval_analyze_cases` for repeatability/coverage/timing and
`eval_compare_runs` for aligned saved results. Check suite/scoring/case/settings
compatibility and missing samples before drawing conclusions. Use approved
baselines and `eval_release_report` for policy checks rather than treating a
pass rate alone as release approval.

Export with `eval_export_run` or portable suite export. Explicit import can add
a run to local history; the `.afevaltrace` host file entrypoint only views it.
Host file URIs are opaque resources, not local paths. Share exports only within
the user's request; they contain original prompts, responses and references.
