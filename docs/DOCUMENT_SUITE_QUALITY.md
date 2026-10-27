# Document-suite quality evaluation

The release gate has separate generation, scoring, and source-review requirements. Review defaults to human; an explicitly authorized agent-review mode records automated provenance. A passing build, valid quote, or successful model request does not establish answer quality.

## Fixed inputs

`Verification/Automation/Fixtures/DocumentQuality/corpus-v1.json` contains 12 synthetic documents, 120 requested drafts, and 28 scoring controls (34 individual requirement checks). Formats include Markdown, text, text PDFs, and a mixed scanned/text PDF. Cases cover permissions, numerical limits, cross-page exceptions, contradictory revisions, and instruction-like content.

`pilot-v1.json` preserves the original permissions false rejection. `holdout-v1.json` adds 28 unseen controls covering negation, omitted roles, boundary conditions, units, and paraphrases. Do not edit expected outcomes to make a failed implementation pass. Version new inputs and retain failed runs.

## Run a fresh evaluation

Each command requires a new absolute output directory. The runner snapshots its input and relevant sources, then invokes the real importer, generator, or scorer through XCTest. It refuses to overwrite an earlier run.

```bash
bash script/run_document_quality.sh semantic /private/tmp/document-semantic-controls
bash script/run_document_quality.sh focus /private/tmp/document-focused-regressions
bash script/run_document_quality.sh generation /private/tmp/document-generation-run
bash script/run_document_quality.sh controls /private/tmp/document-scoring-run
bash script/run_document_quality.sh holdout /private/tmp/document-scoring-holdout
bash script/run_document_quality.sh repairs /private/tmp/document-repair-regressions
bash script/run_document_quality.sh followup /private/tmp/document-followup-regressions
python3 script/document_quality_report.py /private/tmp/document-generation-run \
  --controls /private/tmp/document-scoring-run \
  --semantic-controls /private/tmp/document-semantic-controls
```

The current generator uses the same semantic acceptance pipeline as the app. Its configured independent judge must approve all six checks before a candidate is surfaced. Each passage permits at most three generation/review attempts, including structural citation failures. Repeated identical valid citation anchors are collapsed; unsupported quote wording is never normalized. `semantic-attempts.jsonl` retains rejected candidates and verdicts; provider errors stop that document. Twenty-two frozen semantic controls pair historical defects with valid corrections, including missing exception citations. All 22 must pass, and every surfaced candidate must have a matching approval bound to its exact content and prior questions.

Generation records every attempted passage, requested and actual question type, structured model draft, rejection reason, surfaced case, and duration. Model/OS identity and generation/judge versions are retained. Failed and duplicate attempts remain in the denominator.

The `focus` mode replays the five v10 failures with their exact extracted source, focus passage, requested type, and prior question history from `generation-focus-v1.json`. It records each outcome even after a model or validation failure. Literal scope checks detect the original omissions and mismatches, but independent semantic review is still required; passing those assertions does not establish that every question is well worded. A focused run cannot satisfy the full-corpus gate.

`generation-regressions-v3.json` preserves all 34 previous repair/scope controls and adds 12 positive/negative cases for the five v10 corrections, including explicit read-only autosave behavior.

Scoring uses the actual production runner. Both the whole-case outcome and every requirement must agree with the frozen expected result. A pilot is insufficient for qualification.

To test an explicitly selected independent judge, set `INTENTS_DOCUMENT_QUALITY_JUDGE_CONFIG` to an isolated JSON copy of its connection configuration before both runs. This is opt-in: the harness reads the existing bound Keychain credential and sends only the synthetic fixtures. It does not change the saved connection or suite defaults. Declare a context limit verified for that model; do not invent one to bypass admission. The harness snapshots the configuration, but never writes the credential into results.

The 27 October 2026 `deepseek-flash` qualification used a 1,000,000-token context limit from the provider's [model documentation](https://api-docs.deepseek.com/quick_start/pricing/). The initial credential check required the user to re-enter the existing key in Settings → Judges; the harness did not bypass credential binding. Policy v13 passed all 28 primary controls and all 28 frozen holdout controls, including all 72 individual requirement checks. The previous v12 result (27/28 primary controls) remains retained. The fix allows a concise answer to inherit conditions already fixed by its question, without inventing omitted requested facts.

## Review and qualify

The report creates `review.md`, `sources.md`, `review-template.json`, and `quality-gates.json`. Review the complete extracted source as well as each retained passage; exceptions can occur elsewhere in a document.

Label **every** surfaced draft for source support, usefulness/distinctness, rubric correctness, and acceptance without substantive edits. Retain candidate hashes and truthful reviewer provenance. By default only human labels qualify; automated labels cannot satisfy the human gate. On 27 October 2026 the user explicitly selected agent labeling for this study, so its selected gate uses the automated mode below.

```bash
python3 script/document_quality_report.py /private/tmp/document-generation-run \
  --controls /private/tmp/document-scoring-run \
  --semantic-controls /private/tmp/document-semantic-controls \
  --labels /absolute/path/to/human-review.json
```

Qualification requires at least 10 documents, 100 requested drafts, 100 surfaced drafts, complete labels of the selected reviewer kind, at least 90% source support, and at least 80% acceptance without substantive edits. All frozen scoring controls must pass. Record the independent holdout result separately before promoting a revised scoring policy.

For the user-authorized agent-review study:

```bash
python3 script/document_quality_report.py Verification/DocumentSuiteQuality/2026-10-27/deepseek-generation-v6-v13 \
  --controls Verification/DocumentSuiteQuality/2026-10-27/deepseek-controls-v13 \
  --labels Verification/DocumentSuiteQuality/2026-10-27/deepseek-generation-v6-v13/automated-review.json \
  --reviewer-kind automated
```

`reviewer_kind`, `reviewed`, and `review_complete` identify the selected evidence. `overall_gate_passed` describes that selected policy; `human_reviewed`, `human_review_complete`, and `human_overall_gate_passed` remain zero/false for automated review. The original human-policy report is preserved in `human-policy-snapshot/`. Failed labels are retained and thresholds are unchanged.

The report rejects duplicate attempts, inconsistent summaries, altered source files or retained passages, mismatched label hashes, and scoring results from a different frozen corpus, judge implementation, or runtime configuration. Never combine favorable results from incompatible runs.

## Runtime constraints

The installed AFM 3 Core Advanced runtime has limited reasoning and does not expose deeper reasoning support. The calibration campaign has found false rejections even after separating requirements. Treat its document-scoring qualification as failed until the production controls pass; prompt-format success alone is insufficient.

Apple's `contentTagging` use case always produces tags and is unsuitable for judging requirement satisfaction. `permissiveContentTransformations` affects string responses; guided structured responses retain the default guardrail behavior. Private Cloud Compute additionally requires a managed entitlement: reported device availability does not prove the app can make requests. These constraints were checked through Xcode's Foundation Models documentation.


## Previous v10 evidence

The final study is retained under `Verification/DocumentSuiteQuality/2026-10-27/v10-generation/`. Run the report with its automated labels and sibling `v10-controls/` directory. All 120 labels are fresh assessments. Source support is 96.7% and acceptance without edits is 95.8%; five failed labels remain. The separate `v10-holdout/` and `v10-repairs/` runs also pass. The 34 repair controls are frozen in `generation-regressions-v2.json`; v1 is retained. The paired controls test concrete errors and short correct answers that omit unasked reference details.

Full imported context is preserved and verified for the v7–v10 generator versions. Generation stops before suite context overflow, and the coverage count uses cited passages rather than every retained background passage. The study does not establish that arbitrary documents will produce no defects; the remaining read-only autosave exception demonstrates why draft review remains necessary.

## Fact-first generation

Generator v15 emits the complete source fact before deriving its question. It highlights the focus passage and its immediate neighbors to improve exception retention, while still passing and retaining the complete source. All duplicated context is included in the native token admission check. The generated rubric remains question-scoped, and supporting quotes still require exact source containment. The separate planning and self-review experiments were not adopted; their failed evidence is retained.

## Current v15 generation evidence

The fresh run surfaced 120/120 requested drafts in 124 attempts across 12 documents. Independent automated review found 116/120 supported (96.7%), 120/120 useful/distinct, 117/120 rubric-correct (97.5%), and 116/120 acceptable without edits (96.7%). All 31 selected Swift tests passed. Evidence is under `Verification/DocumentSuiteQuality/2026-10-27/v15-generation/`; the report combines those fresh labels with matching `v15-controls/` evidence.

All five historical v10 drafts have separate reviewed corrections. Four raw v15 drafts remain flagged: projector request wording, an unsupported printer-light/encryption inference, autosave described as a failure, and a before/after operator-approval mismatch. These are retained as failed raw labels. Separate corrections fix those four, including moving the autosave citation to the read-only exclusion. Their eight positive/negative controls are in `generation-followup-v1.json`.

The focused literal regression test passes, but independent review still flags its autosave “failure” wording. The new generator retains the read-only exception in both the focused and full runs; these results do not establish that every generation defect has been eliminated. The original percentage thresholds remain unchanged. See the evidence README for complete scoring and build results.
