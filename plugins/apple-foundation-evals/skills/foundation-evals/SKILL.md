---
name: foundation-evals
description: Run standalone on-device Apple Foundation Models evaluations, including app-format conversations, schemas, tools, rubric scoring and local development workflows.
---

Use `eval_open_workspace` for the native Codex workspace entrypoint. Check
`eval_model_status` before inference. The full app-format engine requires
macOS27 and Xcode27, enabled Apple Intelligence and a downloaded model.

Inspect project/suite state with `eval_list_projects`, `eval_list_suites` and
`eval_project_overview`. Save/import the app suite definition, preserving case
identities, names, model settings, scoring contract and reference attachments.
Use expectedRevision when mutating or executing existing definitions. Drafts
may be incomplete; run admission validates readiness. Never overwrite an
unexpected revision. The UI saves edits automatically.

The app-format suite supports same-model rubric, exact/contains/review scoring,
conversations and history, structured output/field checks, fixture and strict
loopback HTTP tools, session profiles, streaming, prewarming and transcript
capture. Use returned schemas and limits. Remote providers, external judge,
Intent Lab and companion-device execution are outside this plugin's scope.
Legacy flat suites retain their existing per-case scoring semantics.

Start `eval_start_run`, inspect `eval_get_run`, and cancel if requested. Use real
recorded evidence, distinguish unscored/error/failed responses, and never invent
model output, token usage or workflow timings. App scores use1–4; legacy scores
use their original scale.

For instruction comparisons, create/run/read an experiment, then record an
explicit decision. Adopt only if the source revision remains unchanged. Approve
baselines only with complete compatible scored evidence, and use release
reports for policy evaluation. Human corrections preserve original judgments.

The plugin uses its own local store and compiled source-hashed engine. No app
installation, app database or credentials are needed. Tool results can enter
the requesting chat's context; exports include references and transcripts.
